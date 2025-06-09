//! pp-lang 编译器命令行入口。
//!
//! 用法：
//!   pp ir <file>          输出 LLVM IR
//!   pp run <file>         JIT 执行 main 并打印返回值
//!   pp build <file> [-o]  编译并链接为可执行文件

mod ast;
mod codegen;
mod lexer;
mod parser;

use std::path::{Path, PathBuf};
use std::process::Command;

use inkwell::context::Context;
use inkwell::OptimizationLevel;

fn read_file(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("cannot read '{}': {}", path, e))
}

/// 通过 dlsym 查找 libc 等动态库符号地址，供 JIT 解析 extern 函数。
#[cfg(target_os = "macos")]
fn resolve_symbol(name: &str) -> *mut std::ffi::c_void {
    use std::ffi::CString;
    unsafe extern "C" {
        fn dlsym(
            handle: *mut std::ffi::c_void,
            symbol: *const std::ffi::c_char,
        ) -> *mut std::ffi::c_void;
    }
    let c = CString::new(name).unwrap();
    // macOS 上 RTLD_DEFAULT = -2
    unsafe { dlsym((-2isize) as *mut std::ffi::c_void, c.as_ptr()) }
}

#[cfg(target_os = "linux")]
fn resolve_symbol(name: &str) -> *mut std::ffi::c_void {
    use std::ffi::CString;
    // glibc < 2.34 的 dlsym 在 libdl 中，显式链接以兼容老系统。
    #[link(name = "dl")]
    unsafe extern "C" {
        fn dlsym(
            handle: *mut std::ffi::c_void,
            symbol: *const std::ffi::c_char,
        ) -> *mut std::ffi::c_void;
    }
    let c = CString::new(name).unwrap();
    // glibc 上 RTLD_DEFAULT = 0（NULL 即全局命名空间）
    unsafe { dlsym(std::ptr::null_mut(), c.as_ptr()) }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn resolve_symbol(_name: &str) -> *mut std::ffi::c_void {
    std::ptr::null_mut()
}

/// 刷新 libc 输出缓冲，避免 JIT 内 printf 与返回值 echo 乱序。
fn flush_stdout() {
    unsafe extern "C" {
        fn fflush(stream: *mut std::ffi::c_void) -> i32;
    }
    // fflush(NULL) 刷新所有输出流。
    unsafe { fflush(std::ptr::null_mut()) };
}

/// 统一编译流程：struct 类型 → extern 声明 → 函数体。
fn codegen<'ctx>(cg: &mut codegen::Codegen<'ctx>, items: &[ast::Item]) -> Result<(), String> {
    let struct_defs: Vec<&ast::StructDef> = items
        .iter()
        .filter_map(|i| match i {
            ast::Item::Struct(d) => Some(d),
            _ => None,
        })
        .collect();
    cg.declare_structs(&struct_defs)?;

    for item in items {
        if let ast::Item::Extern(p) = item {
            cg.declare_prototype(p)?;
        }
    }
    // 先声明所有用户函数原型，支持前向引用（如 kmain 调用后定义的函数）。
    for item in items {
        if let ast::Item::Function(f) = item {
            cg.declare_prototype(&f.proto)?;
        }
    }
    // 声明全局变量。
    for item in items {
        if let ast::Item::Static(s) = item {
            cg.declare_static(s)?;
        }
    }
    for item in items {
        if let ast::Item::Function(f) = item {
            cg.compile_function(f)?;
        }
    }
    Ok(())
}

/// 完整编译流程：源码 → IR 字符串。
fn compile_to_ir(path: &str) -> Result<String, String> {
    let items = load_program(path)?;
    let context = Context::create();
    let mut cg = codegen::Codegen::new(&context, "main");
    codegen(&mut cg, &items)?;

    Ok(cg.module().print_to_string().to_string())
}

/// 递归展开 `import "..."`，返回扁平的 item 列表。
fn resolve_imports(
    items: Vec<ast::Item>,
    base_dir: &Path,
    out: &mut Vec<ast::Item>,
    visited: &mut Vec<PathBuf>,
) -> Result<(), String> {
    for item in items {
        match item {
            ast::Item::Import(rel) => {
                let canon = base_dir
                    .join(&rel)
                    .canonicalize()
                    .map_err(|e| format!("cannot resolve import '{}': {}", rel, e))?;
                if visited.contains(&canon) {
                    continue;
                }
                visited.push(canon.clone());
                let src = std::fs::read_to_string(&canon)
                    .map_err(|e| format!("cannot read import '{}': {}", rel, e))?;
                let tokens = lexer::tokenize(&src)?;
                let sub = parser::Parser::new(tokens).parse_program()?;
                let sub_dir = canon.parent().unwrap_or(base_dir).to_path_buf();
                resolve_imports(sub, &sub_dir, out, visited)?;
            }
            other => out.push(other),
        }
    }
    Ok(())
}

/// 读取源码、词法、语法、并展开 import，返回最终 item 列表。
fn load_program(path: &str) -> Result<Vec<ast::Item>, String> {
    let src = read_file(path)?;
    let tokens = lexer::tokenize(&src)?;
    let items = parser::Parser::new(tokens).parse_program()?;
    let base = Path::new(path)
        .canonicalize()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));
    let mut out = Vec::new();
    let mut visited = Vec::new();
    resolve_imports(items, &base, &mut out, &mut visited)?;
    Ok(out)
}

fn cmd_ir(file: &str) -> Result<(), String> {
    let ir = compile_to_ir(file)?;
    print!("{}", ir);
    Ok(())
}

fn cmd_run(file: &str) -> Result<(), String> {
    let items = load_program(file)?;
    let context = Context::create();
    let mut cg = codegen::Codegen::new(&context, "main");
    codegen(&mut cg, &items)?;

    let main_fn = cg
        .module()
        .get_function("main")
        .ok_or_else(|| "no 'main' function".to_string())?;

    let engine = cg
        .module()
        .create_jit_execution_engine(OptimizationLevel::None)
        .map_err(|e| e.to_string())?;

    // 解析 extern 函数（如 libc 的 printf/puts）到 JIT 引擎。
    for f in cg.module().get_functions() {
        if f.as_global_value().is_declaration() {
            if let Ok(name) = f.get_name().to_str() {
                let addr = resolve_symbol(name);
                if !addr.is_null() {
                    engine.add_global_mapping(&f, addr as usize);
                }
            }
        }
    }

    // 执行 main 后先 flush libc 的 stdout，避免与返回值 echo 乱序。
    match main_fn.get_type().get_return_type() {
        Some(inkwell::types::BasicTypeEnum::FloatType(_)) => {
            let f = unsafe {
                engine
                    .get_function::<unsafe extern "C" fn() -> f64>("main")
                    .map_err(|e| e.to_string())?
            };
            let v = unsafe { f.call() };
            flush_stdout();
            println!("{}", v);
        }
        _ => {
            let f = unsafe {
                engine
                    .get_function::<unsafe extern "C" fn() -> i32>("main")
                    .map_err(|e| e.to_string())?
            };
            let v = unsafe { f.call() };
            flush_stdout();
            println!("{}", v);
        }
    }
    Ok(())
}

/// 编译并发射目标文件（.o），支持指定目标三元组（用于交叉编译 / freestanding）。
fn emit_object_for_target(
    file: &str,
    output: &str,
    triple: &str,
    reloc: inkwell::targets::RelocMode,
    code_model: inkwell::targets::CodeModel,
) -> Result<(), String> {
    use inkwell::targets::{FileType, InitializationConfig, Target, TargetTriple};

    Target::initialize_all(&InitializationConfig::default());

    let triple = TargetTriple::create(triple);
    let target = Target::from_triple(&triple).map_err(|e| e.to_string())?;
    let machine = target
        .create_target_machine(
            &triple,
            "",
            "",
            OptimizationLevel::None,
            reloc,
            code_model,
        )
        .ok_or_else(|| "failed to create target machine".to_string())?;

    let items = load_program(file)?;
    let context = Context::create();
    let mut cg = codegen::Codegen::new(&context, "main");
    codegen(&mut cg, &items)?;

    machine
        .write_to_file(cg.module(), FileType::Object, Path::new(output))
        .map_err(|e| e.to_string())
}

/// 主机目标（用户态）。
fn emit_object(file: &str, output: &str) -> Result<(), String> {
    use inkwell::targets::{CodeModel, RelocMode, TargetMachine};
    let triple = TargetMachine::get_default_triple();
    let triple = triple.as_str().to_str().unwrap().to_string();
    emit_object_for_target(file, output, &triple, RelocMode::Default, CodeModel::Default)
}

/// freestanding 目标（x86_64 裸机 ELF）。
fn cmd_os(file: &str, output: &str) -> Result<(), String> {
    use inkwell::targets::{CodeModel, RelocMode};
    emit_object_for_target(
        file,
        output,
        "x86_64-unknown-none",
        RelocMode::Static,
        CodeModel::Kernel,
    )
}

fn cmd_obj(file: &str, output: &str) -> Result<(), String> {
    emit_object(file, output)
}

fn cmd_build(file: &str, output: &str) -> Result<(), String> {
    let obj = std::env::temp_dir().join(format!("pp_{}.o", std::process::id()));
    emit_object(file, obj.to_str().unwrap())?;

    // 用系统 C 编译器链接（macOS 上 cc = Apple clang，Linux 上 cc = gcc/clang）。
    let status = Command::new("cc")
        .arg(&obj)
        .arg("-o")
        .arg(output)
        .status()
        .map_err(|e| format!("failed to run cc: {}", e))?;

    if !status.success() {
        return Err("cc linking failed".to_string());
    }
    Ok(())
}

fn print_usage() {
    eprintln!("usage:");
    eprintln!("  pp ir <file>            emit LLVM IR");
    eprintln!("  pp run <file>           JIT run 'main' and print result");
    eprintln!("  pp obj <file> [-o out]  emit object file (.o)");
    eprintln!("  pp os <file> [-o out]   emit freestanding x86_64 ELF object");
    eprintln!("  pp build <file> [-o out]  compile & link to executable");
}

fn parse_output_flag(args: &[String]) -> String {
    args.iter()
        .position(|a| a == "-o")
        .and_then(|i| args.get(i + 1))
        .cloned()
        .unwrap_or_else(|| "a.out".to_string())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        print_usage();
        std::process::exit(1);
    }

    let result = match args[1].as_str() {
        "ir" => cmd_ir(&args[2]),
        "run" => cmd_run(&args[2]),
        "obj" => cmd_obj(&args[2], &parse_output_flag(&args)),
        "os" => cmd_os(&args[2], &parse_output_flag(&args)),
        "build" => cmd_build(&args[2], &parse_output_flag(&args)),
        _ => {
            print_usage();
            std::process::exit(1);
        }
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}
