//! 代码生成：AST → LLVM IR（inkwell）。

use std::collections::HashMap;

use inkwell::AddressSpace;
use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::module::{Linkage, Module};
use inkwell::types::{BasicMetadataTypeEnum, BasicType, BasicTypeEnum, StructType};
use inkwell::values::{
    AggregateValueEnum, BasicMetadataValueEnum, BasicValue, BasicValueEnum,
    FunctionValue, GlobalValue, IntValue, PointerValue,
};
use inkwell::basic_block::BasicBlock;
use inkwell::{AtomicOrdering, AtomicRMWBinOp, FloatPredicate, IntPredicate};

use crate::ast::*;

macro_rules! b {
    ($e:expr) => {
        $e.map_err(|e| e.to_string())?
    };
}

pub struct Codegen<'ctx> {
    context: &'ctx Context,
    module: Module<'ctx>,
    builder: Builder<'ctx>,
    named_values: HashMap<String, (PointerValue<'ctx>, BasicTypeEnum<'ctx>)>,
    struct_defs: HashMap<String, Vec<(String, Type)>>,
    struct_types: HashMap<String, StructType<'ctx>>,
    globals: HashMap<String, (GlobalValue<'ctx>, BasicTypeEnum<'ctx>)>,
    var_types: HashMap<String, Type>,
    func_rets: HashMap<String, Type>,
    func_params: HashMap<String, Vec<Type>>,
    cur_ret: Option<BasicTypeEnum<'ctx>>,
    loop_stack: Vec<(BasicBlock<'ctx>, BasicBlock<'ctx>)>,
    let_prealloc: HashMap<String, (PointerValue<'ctx>, BasicTypeEnum<'ctx>)>,
    defer_stack: Vec<Expr>,
    str_type: StructType<'ctx>,
}

impl<'ctx> Codegen<'ctx> {
    pub fn new(context: &'ctx Context, name: &str) -> Self {
        let module = context.create_module(name);
        module.set_triple(&inkwell::targets::TargetMachine::get_default_triple());
        let builder = context.create_builder();
        let str_type = context.struct_type(
            &[context.i64_type().into(), context.i64_type().into()],
            false,
        );
        Codegen {
            context,
            module,
            builder,
            named_values: HashMap::new(),
            struct_defs: HashMap::new(),
            struct_types: HashMap::new(),
            globals: HashMap::new(),
            var_types: HashMap::new(),
            func_rets: HashMap::new(),
            func_params: HashMap::new(),
            cur_ret: None,
            loop_stack: Vec::new(),
            let_prealloc: HashMap::new(),
            defer_stack: Vec::new(),
            str_type,
        }
    }

    pub fn module(&self) -> &Module<'ctx> {
        &self.module
    }

    /// 注册所有 struct 类型（两阶段：先 opaque，再 set body，支持嵌套/递归）。
    pub fn declare_structs(&mut self, defs: &[&StructDef]) -> Result<(), String> {
        for def in defs {
            self.struct_defs.insert(def.name.clone(), def.fields.clone());
            self.struct_types.insert(
                def.name.clone(),
                self.context.opaque_struct_type(&def.name),
            );
        }
        for def in defs {
            let mut field_types: Vec<BasicTypeEnum<'ctx>> =
                Vec::with_capacity(def.fields.len());
            for (_, t) in &def.fields {
                field_types.push(self.type_to_basic(t)?);
            }
            let st = self.struct_types[&def.name];
            st.set_body(&field_types, false);
        }
        Ok(())
    }

    fn struct_name_for_type(&self, st: StructType<'ctx>) -> Option<String> {
        self.struct_types
            .iter()
            .find(|(_, t)| **t == st)
            .map(|(n, _)| n.clone())
    }

    fn type_to_basic(&self, t: &Type) -> Result<BasicTypeEnum<'ctx>, String> {
        match t {
            Type::Int => Ok(self.context.i32_type().into()),
            Type::Float => Ok(self.context.f64_type().into()),
            Type::Bool => Ok(self.context.bool_type().into()),
            Type::Str => Ok(self.str_type.into()),
            Type::U8 => Ok(self.context.i8_type().into()),
            Type::U16 => Ok(self.context.i16_type().into()),
            Type::U32 => Ok(self.context.i32_type().into()),
            Type::U64 => Ok(self.context.i64_type().into()),
            Type::Array(elem, len) => {
                let elem_ty = self.type_to_basic(elem)?;
                Ok(elem_ty.array_type(*len as u32).into())
            }
            Type::Fn(_, _) => Ok(self.context.ptr_type(AddressSpace::default()).into()),
            Type::Ptr(_) => Ok(self.context.ptr_type(AddressSpace::default()).into()),
            Type::Named(name) => self
                .struct_types
                .get(name)
                .copied()
                .map(|s| s.into())
                .ok_or_else(|| format!("unknown type '{}'", name)),
            Type::Void => Err("'void' is not a value type".to_string()),
        }
    }

    fn fn_type(
        &self,
        proto: &Prototype,
        is_extern: bool,
    ) -> Result<inkwell::types::FunctionType<'ctx>, String> {
        let mut params: Vec<BasicMetadataTypeEnum<'ctx>> =
            Vec::with_capacity(proto.params.len());
        for (_, t) in &proto.params {
            let bt = if is_extern && *t == Type::Str {
                self.context.ptr_type(AddressSpace::default()).into()
            } else {
                self.type_to_basic(t)?
            };
            params.push(bt.into());
        }
        let ft = match &proto.ret {
            Type::Void => self.context.void_type().fn_type(&params, proto.is_var_arg),
            Type::Str if is_extern => self
                .context
                .ptr_type(AddressSpace::default())
                .fn_type(&params, proto.is_var_arg),
            _ => self.type_to_basic(&proto.ret)?.fn_type(&params, proto.is_var_arg),
        };
        Ok(ft)
    }

    /// 声明函数原型（extern 或内部使用），返回对应的 FunctionValue。
    pub fn declare_prototype(
        &mut self,
        proto: &Prototype,
        is_extern: bool,
    ) -> Result<FunctionValue<'ctx>, String> {
        if let Some(f) = self.module.get_function(&proto.name) {
            self.func_rets.insert(proto.name.clone(), proto.ret.clone());
            self.func_params
                .insert(proto.name.clone(), proto.params.iter().map(|(_, t)| t.clone()).collect());
            return Ok(f);
        }
        let ft = self.fn_type(proto, is_extern)?;
        let f = self.module.add_function(&proto.name, ft, Some(Linkage::External));
        for (i, (name, _)) in proto.params.iter().enumerate() {
            if let Some(p) = f.get_nth_param(i as u32) {
                p.set_name(name);
            }
        }
        self.func_rets.insert(proto.name.clone(), proto.ret.clone());
        self.func_params
            .insert(proto.name.clone(), proto.params.iter().map(|(_, t)| t.clone()).collect());
        Ok(f)
    }

    /// 声明一个全局变量（`static`）。
    pub fn declare_static(&mut self, s: &Static) -> Result<(), String> {
        let ty = self.type_to_basic(&s.ty)?;
        let init_val = match &s.init {
            Some(e) => self.const_init(e, &s.ty)?,
            None => self.zero_value(&s.ty)?,
        };
        let gv = self.module.add_global(ty, None, &s.name);
        gv.set_initializer(&init_val);
        self.globals.insert(s.name.clone(), (gv, ty));
        self.var_types.insert(s.name.clone(), s.ty.clone());
        Ok(())
    }

    /// 计算 static 的常量初始化值（支持 int/float 字面量及取负）。
    fn const_init(&self, init: &Expr, ty: &Type) -> Result<BasicValueEnum<'ctx>, String> {
        match init {
            Expr::Int(v) => self.const_int_value(*v, ty),
            Expr::Float(v) => match ty {
                Type::Float => Ok(self.context.f64_type().const_float(*v).into()),
                _ => Err(format!("static initializer type mismatch")),
            },
            Expr::Bool(b) => match ty {
                Type::Bool => Ok(self.context.bool_type().const_int(*b as u64, false).into()),
                _ => Err(format!("static initializer type mismatch")),
            },
            Expr::Unary { op: UnOp::Neg, expr } => match expr.as_ref() {
                Expr::Int(v) => self.const_int_value(-*v, ty),
                Expr::Float(v) => match ty {
                    Type::Float => Ok(self.context.f64_type().const_float(-*v).into()),
                    _ => Err("static initializer type mismatch".to_string()),
                },
                _ => Err("static initializer must be a constant".to_string()),
            },
            _ => Err("static initializer must be a constant".to_string()),
        }
    }

    fn const_int_value(&self, v: i64, ty: &Type) -> Result<BasicValueEnum<'ctx>, String> {
        match ty {
            Type::Int => Ok(self.context.i32_type().const_int(v as u64, false).into()),
            Type::Bool => Ok(self
                .context
                .bool_type()
                .const_int((v != 0) as u64, false)
                .into()),
            Type::U8 => Ok(self.context.i8_type().const_int(v as u64, false).into()),
            Type::U16 => Ok(self.context.i16_type().const_int(v as u64, false).into()),
            Type::U32 => Ok(self.context.i32_type().const_int(v as u64, false).into()),
            Type::U64 => Ok(self.context.i64_type().const_int(v as u64, false).into()),
            _ => Err("static initializer type mismatch".to_string()),
        }
    }

    fn zero_value(&self, ty: &Type) -> Result<BasicValueEnum<'ctx>, String> {
        match ty {
            Type::Int => Ok(self.context.i32_type().const_int(0, false).into()),
            Type::Float => Ok(self.context.f64_type().const_float(0.0).into()),
            Type::Bool => Ok(self.context.bool_type().const_int(0, false).into()),
            Type::U8 => Ok(self.context.i8_type().const_int(0, false).into()),
            Type::U16 => Ok(self.context.i16_type().const_int(0, false).into()),
            Type::U32 => Ok(self.context.i32_type().const_int(0, false).into()),
            Type::U64 => Ok(self.context.i64_type().const_int(0, false).into()),
            Type::Array(elem, len) => {
                let elem_ty = self.type_to_basic(elem)?;
                Ok(elem_ty.array_type(*len as u32).const_zero().into())
            }
            Type::Ptr(_) => Ok(self
                .context
                .ptr_type(AddressSpace::default())
                .const_null()
                .into()),
            Type::Fn(_, _) => Ok(self
                .context
                .ptr_type(AddressSpace::default())
                .const_null()
                .into()),
            Type::Str => Ok(self.str_type.const_zero().into()),
            Type::Named(name) => {
                let st = self
                    .struct_types
                    .get(name)
                    .copied()
                    .ok_or_else(|| format!("unknown type '{}'", name))?;
                Ok(st.const_zero().into())
            }
            Type::Void => Err("'void' static is not allowed".to_string()),
        }
    }

    /// 把值强制转换到目标类型（int 收窄用 truncate，拓宽用 zext）。
    fn coerce(
        &self,
        val: BasicValueEnum<'ctx>,
        target: BasicTypeEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if val.get_type() == target {
            return Ok(val);
        }
        match (val, target) {
            (BasicValueEnum::IntValue(iv), BasicTypeEnum::IntType(it)) => {
                let src_w = iv.get_type().get_bit_width();
                let dst_w = it.get_bit_width();
                if dst_w == 1 && src_w != 1 {
                    Err(
                        "implicit int to bool conversion; use (x != 0) or explicit cast"
                            .to_string(),
                    )
                } else if src_w > dst_w {
                    // 仅禁止向「字节级窄类型」静默截断：u64→u8/u16 才是隐患；
                    // u64→int/u32（低地址无损）与 int→u8/u16（字节填充惯用）保留。
                    if dst_w >= 32 || src_w <= 32 || iv.is_const() {
                        Ok(b!(self.builder.build_int_truncate(iv, it, "coerce")).into())
                    } else {
                        Err(format!(
                            "implicit narrowing from i{} to i{}; use explicit cast (x as T)",
                            src_w, dst_w
                        ))
                    }
                } else if src_w < dst_w {
                    Ok(b!(self.builder.build_int_z_extend(iv, it, "coerce")).into())
                } else {
                    Ok(iv.into())
                }
            }
            (BasicValueEnum::IntValue(iv), BasicTypeEnum::PointerType(pt)) => {
                Ok(b!(self.builder.build_int_to_ptr(iv, pt, "coerce")).into())
            }
            (BasicValueEnum::PointerValue(pv), BasicTypeEnum::IntType(it)) => {
                Ok(b!(self.builder.build_ptr_to_int(pv, it, "coerce")).into())
            }
            _ => Err(format!(
                "type mismatch: cannot coerce {} to {}",
                val.get_type().print_to_string(),
                target.print_to_string()
            )),
        }
    }

    /// 整数提升：把较窄的操作数 zext 到较宽的类型。
    fn promote_int(
        &self,
        a: IntValue<'ctx>,
        b: IntValue<'ctx>,
    ) -> Result<(IntValue<'ctx>, IntValue<'ctx>), String> {
        let wa = a.get_type().get_bit_width();
        let wb = b.get_type().get_bit_width();
        if wa == wb {
            return Ok((a, b));
        }
        if wa < wb {
            let t = b.get_type();
            let a2 = b!(self.builder.build_int_z_extend(a, t, "promote"));
            Ok((a2, b))
        } else {
            let t = a.get_type();
            let b2 = b!(self.builder.build_int_z_extend(b, t, "promote"));
            Ok((a, b2))
        }
    }
    pub fn compile_function(&mut self, func: &Function) -> Result<FunctionValue<'ctx>, String> {
        if let Some(existing) = self.module.get_function(&func.proto.name) {
            if existing.count_basic_blocks() > 0 {
                return Err(format!(
                    "duplicate function definition '{}'",
                    func.proto.name
                ));
            }
        }
        self.named_values.clear();
        self.let_prealloc.clear();
        self.defer_stack.clear();
        let llvm_fn = self.declare_prototype(&func.proto, false)?;
        self.cur_ret = match &func.proto.ret {
            Type::Void => None,
            t => Some(self.type_to_basic(t)?),
        };

        let entry = self.context.append_basic_block(llvm_fn, "entry");
        self.builder.position_at_end(entry);

        for (i, (name, ty)) in func.proto.params.iter().enumerate() {
            if let Some(p) = llvm_fn.get_nth_param(i as u32) {
                let param_ty = self.type_to_basic(ty)?;
                let alloca = b!(self.builder.build_alloca(param_ty, name));
                b!(self.builder.build_store(alloca, p));
                self.named_values.insert(name.clone(), (alloca, param_ty));
                self.var_types.insert(name.clone(), ty.clone());
            }
        }

        // 预扫描：所有 `let` 的 alloca 统一建在入口块（避免循环体内每迭代动态分配栈）。
        self.prescan_lets(&func.body.stmts)?;

        for stmt in &func.body.stmts {
            self.compile_stmt(stmt)?;
        }

        // 若无显式 return，补一个默认返回。
        if self
            .builder
            .get_insert_block()
            .is_some_and(|b| b.get_terminator().is_none())
        {
            self.emit_defers()?;
            self.emit_default_return(&func.proto.ret)?;
        }

        Ok(llvm_fn)
    }

    /// 递归收集函数内所有 `let`，在入口块预建 alloca（保证栈帧静态固定，循环不泄漏栈）。
    fn prescan_lets(&mut self, stmts: &[Stmt]) -> Result<(), String> {
        for s in stmts {
            match s {
                Stmt::Let { name, ty, init } => {
                    let ast_ty = match ty {
                        Some(t) => t.clone(),
                        None => match init {
                            Some(e) => self.typeof_expr(e),
                            None => return Err("let requires a type or initializer".to_string()),
                        },
                    };
                    let alloc_ty = self.type_to_basic(&ast_ty)?;
                    let alloca = b!(self.builder.build_alloca(alloc_ty, name));
                    self.let_prealloc
                        .entry(name.clone())
                        .or_insert((alloca, alloc_ty));
                    self.var_types.insert(name.clone(), ast_ty);
                }
                Stmt::If { then, els, .. } => {
                    self.prescan_lets(&then.stmts)?;
                    if let Some(e) = els {
                        self.prescan_lets(&e.stmts)?;
                    }
                }
                Stmt::While { body, .. } => {
                    self.prescan_lets(&body.stmts)?;
                }
                Stmt::For { var, iter, body } => {
                    let var_ty = match self.typeof_expr(iter) {
                        Type::Array(elem, _) => *elem,
                        _ => Type::Int,
                    };
                    let alloc_ty = self.type_to_basic(&var_ty)?;
                    let alloca = b!(self.builder.build_alloca(alloc_ty, var));
                    self.let_prealloc
                        .entry(var.clone())
                        .or_insert((alloca, alloc_ty));
                    self.var_types.insert(var.clone(), var_ty);
                    self.prescan_lets(&body.stmts)?;
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// 按 LIFO 执行 defer 语句（函数退出点调用）。
    fn emit_defers(&mut self) -> Result<(), String> {
        while let Some(e) = self.defer_stack.pop() {
            self.compile_expr(&e)?;
        }
        Ok(())
    }

    fn emit_default_return(&self, ret: &Type) -> Result<(), String> {
        match ret {
            Type::Void => {
                b!(self.builder.build_return(None));
            }
            Type::Int => {
                let z = self.context.i32_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::Float => {
                let z = self.context.f64_type().const_float(0.0);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::Bool => {
                let z = self.context.bool_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::U8 => {
                let z = self.context.i8_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::U16 => {
                let z = self.context.i16_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::U32 => {
                let z = self.context.i32_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::U64 => {
                let z = self.context.i64_type().const_int(0, false);
                b!(self.builder.build_return(Some(&z)));
            }
            Type::Array(elem, len) => {
                let elem_ty = self.type_to_basic(elem)?;
                let z = elem_ty.array_type(*len as u32).const_zero();
                b!(self.builder.build_return(Some(&z)));
            }
            Type::Ptr(_) => {
                let null = self
                    .context
                    .ptr_type(AddressSpace::default())
                    .const_null();
                b!(self.builder.build_return(Some(&null)));
            }
            Type::Fn(_, _) => {
                let null = self
                    .context
                    .ptr_type(AddressSpace::default())
                    .const_null();
                b!(self.builder.build_return(Some(&null)));
            }
            Type::Str => {
                let z = self.str_type.const_zero();
                b!(self.builder.build_return(Some(&z)));
            }
            Type::Named(name) => {
                let st = self
                    .struct_types
                    .get(name)
                    .copied()
                    .ok_or_else(|| format!("unknown type '{}'", name))?;
                let z = st.const_zero();
                b!(self.builder.build_return(Some(&z)));
            }
        }
        Ok(())
    }

    // ---------------------------------------------------------------
    // 语句
    // ---------------------------------------------------------------

    fn compile_stmt(&mut self, stmt: &Stmt) -> Result<(), String> {
        match stmt {
            Stmt::Return(Some(e)) => {
                let v = self.compile_expr(e)?;
                let v = match self.cur_ret {
                    Some(rt) => self.coerce(v, rt).map_err(|e| format!("return: {}", e))?,
                    None => return Err(format!("cannot return a value from void function")),
                };
                self.emit_defers()?;
                b!(self.builder.build_return(Some(&v)));
            }
            Stmt::Return(None) => {
                self.emit_defers()?;
                b!(self.builder.build_return(None));
            }
            Stmt::Expr(e) => {
                self.compile_expr(e)?;
            }
            Stmt::Let { name, ty, init } => {
                let pre = self.let_prealloc.get(name).copied();
                let (alloca, alloc_ty) = if let Some((ptr, slot_ty)) = pre {
                    /* 同名同类型复用；显式类型不同（不同作用域）则新建独立 alloca */
                    let mismatch = match ty {
                        Some(t) => match self.type_to_basic(t) {
                            Ok(bt) => bt != slot_ty,
                            Err(_) => false,
                        },
                        None => false,
                    };
                    if mismatch {
                        self.let_prealloc.remove(name);
                        let alloc_ty = self.type_to_basic(ty.as_ref().unwrap())?;
                        let alloca = b!(self.builder.build_alloca(alloc_ty, name));
                        (alloca, alloc_ty)
                    } else {
                        (ptr, slot_ty)
                    }
                } else {
                    let alloc_ty = match ty {
                        Some(t) => self.type_to_basic(t)?,
                        None => match init {
                            Some(e) => self.compile_expr(e)?.get_type(),
                            None => return Err("let requires a type or initializer".to_string()),
                        },
                    };
                    let alloca = b!(self.builder.build_alloca(alloc_ty, name));
                    (alloca, alloc_ty)
                };
                let init_val = match init {
                    Some(e) => {
                        let v = self.compile_expr(e)?;
                        self.coerce(v, alloc_ty)
                            .map_err(|e| format!("let {}: {}", name, e))?
                    }
                    None => match ty {
                        Some(t) => self.zero_value(t)?,
                        None => return Err("let requires an initializer".to_string()),
                    },
                };
                b!(self.builder.build_store(alloca, init_val));
                self.named_values.insert(name.clone(), (alloca, alloc_ty));
                let ast_ty = match ty {
                    Some(t) => t.clone(),
                    None => self.typeof_expr(init.as_ref().unwrap()),
                };
                self.var_types.insert(name.clone(), ast_ty);
            }
            Stmt::AssignIndex { lhs, value } => {
                let (ptr, elem_ty) = self.compile_lvalue_addr(lhs)?;
                let val = self.compile_expr(value)?;
                let val = self.coerce(val, elem_ty).map_err(|e| format!("index assign: {}", e))?;
                b!(self.builder.build_store(ptr, val));
            }
            Stmt::Assign { name, value } => {
                let val = self.compile_expr(value)?;
                if let Some((ptr, ty)) = self.named_values.get(name).copied() {
                    let val = self.coerce(val, ty).map_err(|e| format!("assign {}: {}", name, e))?;
                    b!(self.builder.build_store(ptr, val));
                } else if let Some((gv, ty)) = self.globals.get(name).copied() {
                    let val = self.coerce(val, ty).map_err(|e| format!("assign {}: {}", name, e))?;
                    b!(self.builder.build_store(gv.as_pointer_value(), val));
                } else {
                    return Err(format!("unknown variable '{}'", name));
                }
            }
            Stmt::If { cond, then, els } => self.compile_if(cond, then, els.as_ref())?,
            Stmt::While { cond, body } => self.compile_while(cond, body)?,
            Stmt::For { var, iter, body } => self.compile_for(var, iter, body)?,
            Stmt::Defer(e) => {
                self.defer_stack.push((**e).clone());
            }
            Stmt::Break => {
                let (_, after) = self
                    .loop_stack
                    .last()
                    .copied()
                    .ok_or_else(|| "break outside loop".to_string())?;
                b!(self.builder.build_unconditional_branch(after));
            }
            Stmt::Continue => {
                let (cond, _) = self
                    .loop_stack
                    .last()
                    .copied()
                    .ok_or_else(|| "continue outside loop".to_string())?;
                b!(self.builder.build_unconditional_branch(cond));
            }
        }
        Ok(())
    }

    fn compile_cond(&self, cond: &Expr) -> Result<IntValue<'ctx>, String> {
        let v = self.compile_expr(cond)?;
        match v {
            BasicValueEnum::IntValue(iv) => {
                if iv.get_type().get_bit_width() == 1 {
                    Ok(iv)
                } else {
                    Ok(b!(self.builder.build_int_compare(
                        IntPredicate::NE,
                        iv,
                        self.context.i32_type().const_int(0, false),
                        "ifcond",
                    )))
                }
            }
            _ => Err("condition must be bool or int".to_string()),
        }
    }

    fn compile_if(
        &mut self,
        cond: &Expr,
        then: &Block,
        els: Option<&Block>,
    ) -> Result<(), String> {
        let cond_i1 = self.compile_cond(cond)?;

        let parent = self.builder.get_insert_block().unwrap();
        let function = parent.get_parent().unwrap();
        let then_bb = self.context.append_basic_block(function, "then");
        let else_bb = els
            .map(|_| self.context.append_basic_block(function, "else"));
        let merge_bb = self.context.append_basic_block(function, "ifcont");

        b!(self
            .builder
            .build_conditional_branch(cond_i1, then_bb, else_bb.unwrap_or(merge_bb)));

        // then
        self.builder.position_at_end(then_bb);
        for s in &then.stmts {
            self.compile_stmt(s)?;
        }
        if self
            .builder
            .get_insert_block()
            .is_some_and(|b| b.get_terminator().is_none())
        {
            b!(self.builder.build_unconditional_branch(merge_bb));
        }

        // else
        if let (Some(eb), Some(block)) = (else_bb, els) {
            self.builder.position_at_end(eb);
            for s in &block.stmts {
                self.compile_stmt(s)?;
            }
            if self
                .builder
                .get_insert_block()
                .is_some_and(|b| b.get_terminator().is_none())
            {
                b!(self.builder.build_unconditional_branch(merge_bb));
            }
        }

        self.builder.position_at_end(merge_bb);
        Ok(())
    }

    fn compile_while(&mut self, cond: &Expr, body: &Block) -> Result<(), String> {
        let parent = self.builder.get_insert_block().unwrap();
        let function = parent.get_parent().unwrap();
        let cond_bb = self.context.append_basic_block(function, "whilecond");
        let body_bb = self.context.append_basic_block(function, "whilebody");
        let after_bb = self.context.append_basic_block(function, "whileafter");

        b!(self.builder.build_unconditional_branch(cond_bb));

        // 条件判断
        self.builder.position_at_end(cond_bb);
        let cond_i1 = self.compile_cond(cond)?;
        b!(self
            .builder
            .build_conditional_branch(cond_i1, body_bb, after_bb));

        // 循环体
        self.builder.position_at_end(body_bb);
        self.loop_stack.push((cond_bb, after_bb));
        for s in &body.stmts {
            self.compile_stmt(s)?;
        }
        self.loop_stack.pop();
        if self
            .builder
            .get_insert_block()
            .is_some_and(|b| b.get_terminator().is_none())
        {
            b!(self.builder.build_unconditional_branch(cond_bb));
        }

        self.builder.position_at_end(after_bb);
        Ok(())
    }

    /// `for x in s` 循环：s 为数组（遍历元素）或 `range(n)`（遍历 0..n）。
    fn compile_for(&mut self, var: &str, iter: &Expr, body: &Block) -> Result<(), String> {
        let (var_alloca, var_ty) = self
            .let_prealloc
            .get(var)
            .copied()
            .ok_or_else(|| "for loop variable not preallocated".to_string())?;

        let i32_ty = self.context.i32_type();
        let i_alloca = b!(self.builder.build_alloca(i32_ty, "fori"));

        let parent = self.builder.get_insert_block().unwrap();
        let function = parent.get_parent().unwrap();
        let cond_bb = self.context.append_basic_block(function, "forcond");
        let body_bb = self.context.append_basic_block(function, "forbody");
        let after_bb = self.context.append_basic_block(function, "forafter");

        let is_range = matches!(
            iter,
            Expr::Call { callee, args } if callee == "range" && args.len() == 1
        );

        // 数组：首元素地址 + 元素类型（range 时为 None）。
        let (elem_ptr, elem_ty) = if is_range {
            (None, None)
        } else {
            let it_ty = self.typeof_expr(iter);
            match it_ty {
                Type::Array(..) => {
                    let idx_expr = Expr::Index {
                        base: Box::new(iter.clone()),
                        index: Box::new(Expr::Int(0)),
                    };
                    let (ptr, ety) = self.compile_lvalue_addr(&idx_expr)?;
                    (Some(ptr), Some(ety))
                }
                _ => return Err("for loop requires an array or range(n)".to_string()),
            }
        };

        // 上界：range 时是运行时 n，数组时是编译期常量。
        let limit_i: IntValue<'ctx> = if is_range {
            if let Expr::Call { args, .. } = iter {
                match self.compile_expr(&args[0])? {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("range(n) requires an int".to_string()),
                }
            } else {
                unreachable!()
            }
        } else {
            i32_ty.const_int(match self.typeof_expr(iter) {
                Type::Array(_, n) => n as u64,
                _ => unreachable!(),
            }, false)
        };

        // i = 0
        b!(self.builder.build_store(i_alloca, i32_ty.const_int(0, false)));
        b!(self.builder.build_unconditional_branch(cond_bb));

        // cond: i < limit
        self.builder.position_at_end(cond_bb);
        let i_cond = match b!(self.builder.build_load(i32_ty, i_alloca, "fori")) {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("for index must be int".to_string()),
        };
        let cond_i1 = b!(self
            .builder
            .build_int_compare(IntPredicate::SLT, i_cond, limit_i, "forcmp"));
        b!(self
            .builder
            .build_conditional_branch(cond_i1, body_bb, after_bb));

        // body
        self.builder.position_at_end(body_bb);
        self.loop_stack.push((cond_bb, after_bb));
        self.named_values.insert(var.to_string(), (var_alloca, var_ty));

        let i_body = match b!(self.builder.build_load(i32_ty, i_alloca, "fori")) {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("for index must be int".to_string()),
        };
        if is_range {
            // var = i
            b!(self.builder.build_store(var_alloca, i_body));
        } else {
            // var = arr[i]
            let gep = b!(unsafe {
                self.builder
                    .build_gep(elem_ty.unwrap(), elem_ptr.unwrap(), &[i_body], "forelem")
            });
            let loaded = b!(self.builder.build_load(var_ty, gep, "forval"));
            b!(self.builder.build_store(var_alloca, loaded));
        }

        for s in &body.stmts {
            self.compile_stmt(s)?;
        }
        self.loop_stack.pop();

        // i = i + 1
        let i_after = match b!(self.builder.build_load(i32_ty, i_alloca, "fori")) {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("for index must be int".to_string()),
        };
        let i_next = b!(self
            .builder
            .build_int_add(i_after, i32_ty.const_int(1, false), "forinc"));
        b!(self.builder.build_store(i_alloca, i_next));
        if self
            .builder
            .get_insert_block()
            .is_some_and(|b| b.get_terminator().is_none())
        {
            b!(self.builder.build_unconditional_branch(cond_bb));
        }

        self.builder.position_at_end(after_bb);
        Ok(())
    }

    // ---------------------------------------------------------------
    // 表达式
    // ---------------------------------------------------------------

    /// `x in s` 成员判断：数组（遍历找元素）或字符串（字符查找），返回 bool。
    fn compile_in(&self, lhs: &Expr, rhs: &Expr) -> Result<BasicValueEnum<'ctx>, String> {
        match self.typeof_expr(rhs) {
            Type::Array(elem, len) => self.compile_in_array(lhs, rhs, &elem, len),
            Type::Str => self.compile_in_str(lhs, rhs),
            _ => Err("'in' requires an array or string on the right".to_string()),
        }
    }

    fn compile_in_array(
        &self,
        lhs: &Expr,
        rhs: &Expr,
        elem: &Type,
        len: usize,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let lhs_val = self.compile_expr(lhs)?;
        let elem_ty = self.type_to_basic(elem)?;

        let idx_expr = Expr::Index {
            base: Box::new(rhs.clone()),
            index: Box::new(Expr::Int(0)),
        };
        let (arr_ptr, _) = self.compile_lvalue_addr(&idx_expr)?;

        let bool_ty = self.context.bool_type();
        let result = b!(self.builder.build_alloca(bool_ty, "inresult"));
        b!(self.builder.build_store(result, bool_ty.const_int(0, false)));

        let i32_ty = self.context.i32_type();
        let i_alloca = b!(self.builder.build_alloca(i32_ty, "ini"));

        let parent = self.builder.get_insert_block().unwrap();
        let function = parent.get_parent().unwrap();
        let cond_bb = self.context.append_basic_block(function, "incond");
        let body_bb = self.context.append_basic_block(function, "inbody");
        let done_bb = self.context.append_basic_block(function, "indone");

        b!(self.builder.build_store(i_alloca, i32_ty.const_int(0, false)));
        b!(self.builder.build_unconditional_branch(cond_bb));

        // cond: i < len
        self.builder.position_at_end(cond_bb);
        let i = self.load_int(i_alloca, "ini")?;
        let cond = b!(self.builder.build_int_compare(
            IntPredicate::SLT,
            i,
            i32_ty.const_int(len as u64, false),
            "incmp"
        ));
        b!(self.builder.build_conditional_branch(cond, body_bb, done_bb));

        // body: if lhs == arr[i] { result = true; goto done }
        self.builder.position_at_end(body_bb);
        let i = self.load_int(i_alloca, "ini")?;
        let gep = b!(unsafe { self.builder.build_gep(elem_ty, arr_ptr, &[i], "inelem") });
        let elem_val = b!(self.builder.build_load(elem_ty, gep, "inval"));
        let eq = self.compile_cmp(BinOp::Eq, lhs_val, elem_val)?;
        let eq_i1 = match eq {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("membership comparison must be int".to_string()),
        };

        let match_bb = self.context.append_basic_block(function, "inmatch");
        let nomatch_bb = self.context.append_basic_block(function, "innomatch");
        b!(self.builder.build_conditional_branch(eq_i1, match_bb, nomatch_bb));

        self.builder.position_at_end(match_bb);
        b!(self.builder.build_store(result, bool_ty.const_int(1, false)));
        b!(self.builder.build_unconditional_branch(done_bb));

        self.builder.position_at_end(nomatch_bb);
        let i = self.load_int(i_alloca, "ini")?;
        let i_next = b!(self
            .builder
            .build_int_add(i, i32_ty.const_int(1, false), "ininc"));
        b!(self.builder.build_store(i_alloca, i_next));
        b!(self.builder.build_unconditional_branch(cond_bb));

        self.builder.position_at_end(done_bb);
        Ok(b!(self.builder.build_load(bool_ty, result, "inload")))
    }

    fn compile_in_str(&self, lhs: &Expr, rhs: &Expr) -> Result<BasicValueEnum<'ctx>, String> {
        let lhs_val = self.compile_expr(lhs)?;
        let s_val = self.compile_expr(rhs)?;
        let s_ptr = match s_val {
            BasicValueEnum::PointerValue(p) => p,
            _ => return Err("'in' with string requires a string pointer".to_string()),
        };

        let i8_ty = self.context.i8_type();
        let bool_ty = self.context.bool_type();
        let ptr_ty = self.context.ptr_type(AddressSpace::default());
        let result = b!(self.builder.build_alloca(bool_ty, "inresult"));
        b!(self.builder.build_store(result, bool_ty.const_int(0, false)));
        let p_alloca = b!(self.builder.build_alloca(ptr_ty, "inp"));
        b!(self.builder.build_store(p_alloca, s_ptr));

        let parent = self.builder.get_insert_block().unwrap();
        let function = parent.get_parent().unwrap();
        let cond_bb = self.context.append_basic_block(function, "incond");
        let body_bb = self.context.append_basic_block(function, "inbody");
        let done_bb = self.context.append_basic_block(function, "indone");

        b!(self.builder.build_unconditional_branch(cond_bb));

        // cond: *p != 0
        self.builder.position_at_end(cond_bb);
        let p = match b!(self.builder.build_load(ptr_ty, p_alloca, "inp")) {
            BasicValueEnum::PointerValue(p) => p,
            _ => return Err("string pointer expected".to_string()),
        };
        let c = match b!(self.builder.build_load(i8_ty, p, "inc")) {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("string char must be int".to_string()),
        };
        let cond = b!(self.builder.build_int_compare(
            IntPredicate::NE,
            c,
            i8_ty.const_int(0, false),
            "instrcmp"
        ));
        b!(self.builder.build_conditional_branch(cond, body_bb, done_bb));

        // body: if *p == x { result = true; goto done }
        self.builder.position_at_end(body_bb);
        let p = match b!(self.builder.build_load(ptr_ty, p_alloca, "inp")) {
            BasicValueEnum::PointerValue(p) => p,
            _ => return Err("string pointer expected".to_string()),
        };
        let c = match b!(self.builder.build_load(i8_ty, p, "inc")) {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("string char must be int".to_string()),
        };
        let eq = self.compile_cmp(BinOp::Eq, lhs_val, c.into())?;
        let eq_i1 = match eq {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("membership comparison must be int".to_string()),
        };
        let match_bb = self.context.append_basic_block(function, "inmatch");
        let nomatch_bb = self.context.append_basic_block(function, "innomatch");
        b!(self.builder.build_conditional_branch(eq_i1, match_bb, nomatch_bb));

        self.builder.position_at_end(match_bb);
        b!(self.builder.build_store(result, bool_ty.const_int(1, false)));
        b!(self.builder.build_unconditional_branch(done_bb));

        // nomatch: p++
        self.builder.position_at_end(nomatch_bb);
        let p = match b!(self.builder.build_load(ptr_ty, p_alloca, "inp")) {
            BasicValueEnum::PointerValue(p) => p,
            _ => return Err("string pointer expected".to_string()),
        };
        let one = self.context.i32_type().const_int(1, false);
        let p_next = b!(unsafe { self.builder.build_gep(i8_ty, p, &[one], "innext") });
        b!(self.builder.build_store(p_alloca, p_next));
        b!(self.builder.build_unconditional_branch(cond_bb));

        self.builder.position_at_end(done_bb);
        Ok(b!(self.builder.build_load(bool_ty, result, "inload")))
    }

    /// 从 alloca 加载一个 int 值（for/in 循环索引用）。
    fn load_int(&self, alloca: PointerValue<'ctx>, name: &str) -> Result<IntValue<'ctx>, String> {
        match b!(self.builder.build_load(self.context.i32_type(), alloca, name)) {
            BasicValueEnum::IntValue(iv) => Ok(iv),
            _ => Err(format!("{} must be int", name)),
        }
    }

    /// 构造 str 切片值 `{ptr, len}`（两个 i64，arm64 ABI 可靠）。
    fn make_str(&self, ptr: PointerValue<'ctx>, len: u64) -> BasicValueEnum<'ctx> {
        let len_v = self.context.i64_type().const_int(len, false);
        self.make_str_v(ptr, len_v)
    }

    /// 构造 str 切片值，len 为运行时值（i64）。
    fn make_str_v(&self, ptr: PointerValue<'ctx>, len: IntValue<'ctx>) -> BasicValueEnum<'ctx> {
        let ptr_i: BasicValueEnum<'ctx> = self
            .builder
            .build_ptr_to_int(ptr, self.context.i64_type(), "strptri")
            .unwrap()
            .into();
        let mut agg: AggregateValueEnum<'ctx> = self.str_type.const_zero().into();
        agg = self
            .builder
            .build_insert_value(agg, ptr_i, 0, "strptr")
            .unwrap();
        let len_v: BasicValueEnum<'ctx> = len.into();
        agg = self
            .builder
            .build_insert_value(agg, len_v, 1, "strlen")
            .unwrap();
        agg.as_basic_value_enum()
    }

    /// 提取 str 切片的 ptr 字段（兼容裸指针直接通过）。
    fn str_ptr(&self, v: BasicValueEnum<'ctx>) -> Result<PointerValue<'ctx>, String> {
        match v {
            BasicValueEnum::StructValue(sv) => {
                let f = b!(self.builder.build_extract_value(sv, 0, "strptr"));
                match f {
                    BasicValueEnum::IntValue(iv) => {
                        let p = b!(self.builder.build_int_to_ptr(
                            iv,
                            self.context.ptr_type(AddressSpace::default()),
                            "strptr2"
                        ));
                        Ok(p)
                    }
                    BasicValueEnum::PointerValue(p) => Ok(p),
                    _ => Err("str ptr field is not an int".to_string()),
                }
            }
            BasicValueEnum::PointerValue(p) => Ok(p),
            _ => Err("expected str or pointer".to_string()),
        }
    }

    /// 提取 str 切片的 len 字段（返回 i64，调用方可 truncate 到 int）。
    fn str_len(&self, v: BasicValueEnum<'ctx>) -> Result<IntValue<'ctx>, String> {
        match v {
            BasicValueEnum::StructValue(sv) => {
                let f = b!(self.builder.build_extract_value(sv, 1, "strlen"));
                match f {
                    BasicValueEnum::IntValue(iv) => Ok(iv),
                    _ => Err("str len field is not an int".to_string()),
                }
            }
            _ => Err("expected str".to_string()),
        }
    }

    /// 函数指针间接调用：`fp(args)`，fp 为 `fn(...) -> ...` 类型变量。
    fn compile_indirect_call(
        &self,
        callee: &str,
        params: &[Type],
        ret: &Type,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let ptr_ty = self.context.ptr_type(AddressSpace::default());
        let fnptr = if let Some((ptr, _)) = self.named_values.get(callee).copied() {
            match b!(self.builder.build_load(ptr_ty, ptr, "fnptr")) {
                BasicValueEnum::PointerValue(p) => p,
                _ => return Err("function pointer expected".to_string()),
            }
        } else if let Some((gv, _)) = self.globals.get(callee).copied() {
            match b!(self
                .builder
                .build_load(ptr_ty, gv.as_pointer_value(), "fnptr"))
            {
                BasicValueEnum::PointerValue(p) => p,
                _ => return Err("function pointer expected".to_string()),
            }
        } else {
            return Err(format!("unknown function '{}'", callee));
        };

        let mut pts: Vec<BasicMetadataTypeEnum<'ctx>> = Vec::with_capacity(params.len());
        for p in params {
            pts.push(self.type_to_basic(p)?.into());
        }
        let fn_ty = match ret {
            Type::Void => self.context.void_type().fn_type(&pts, false),
            t => self.type_to_basic(t)?.fn_type(&pts, false),
        };

        let mut compiled: Vec<BasicMetadataValueEnum<'ctx>> = Vec::with_capacity(args.len());
        for (i, a) in args.iter().enumerate() {
            let v = self.compile_expr(a)?;
            let v = if i < params.len() {
                let pt = self.type_to_basic(&params[i])?;
                self.coerce(v, pt)
                    .map_err(|e| format!("arg {} of {}: {}", i, callee, e))?
            } else {
                v
            };
            compiled.push(v.into());
        }

        let call = b!(self
            .builder
            .build_indirect_call(fn_ty, fnptr, &compiled, "indirectcall"));
        match call.try_as_basic_value().basic() {
            Some(v) => Ok(v),
            None => Ok(self.context.i32_type().const_int(0, false).into()),
        }
    }

    // ---------------------------------------------------------------
    // 表达式
    // ---------------------------------------------------------------

    fn compile_expr(&self, expr: &Expr) -> Result<BasicValueEnum<'ctx>, String> {
        match expr {
            Expr::Int(v) => Ok(self.context.i32_type().const_int(*v as u64, false).into()),
            Expr::Float(v) => Ok(self.context.f64_type().const_float(*v).into()),
            Expr::Bool(b) => Ok(self.context.bool_type().const_int(*b as u64, false).into()),
            Expr::Str(s) => {
                let g = b!(self.builder.build_global_string_ptr(s, "str"));
                Ok(self.make_str(g.as_pointer_value(), s.len() as u64))
            }
            Expr::Var(name) => {
                if let Some((ptr, ty)) = self.named_values.get(name).copied() {
                    Ok(b!(self.builder.build_load(ty, ptr, name)))
                } else if let Some((gv, ty)) = self.globals.get(name).copied() {
                    let ptr = gv.as_pointer_value();
                    Ok(b!(self.builder.build_load(ty, ptr, name)))
                } else {
                    Err(format!("unknown variable '{}'", name))
                }
            }
            Expr::Binary { op, lhs, rhs } => {
                if *op == BinOp::In {
                    return self.compile_in(lhs, rhs);
                }
                // 指针算术：p + i、i + p、p - i
                if matches!(op, BinOp::Add | BinOp::Sub) {
                    let lt = self.typeof_expr(lhs);
                    let rt = self.typeof_expr(rhs);
                    if matches!(lt, Type::Ptr(_) | Type::Str) {
                        return self.compile_ptr_arith(*op, lhs, rhs, true);
                    }
                    if matches!(rt, Type::Ptr(_) | Type::Str) {
                        return self.compile_ptr_arith(*op, rhs, lhs, false);
                    }
                }
                let l = self.compile_expr(lhs)?;
                let r = self.compile_expr(rhs)?;
                self.compile_binary(*op, l, r)
            }
            Expr::Unary { op, expr } => {
                let v = self.compile_expr(expr)?;
                self.compile_unary(*op, v)
            }
            Expr::Call { callee, args } => match self.module.get_function(callee) {
                Some(f) => {
                    let is_extern = f.as_global_value().is_declaration();
                    let mut compiled: Vec<BasicMetadataValueEnum<'ctx>> =
                        Vec::with_capacity(args.len());
                    let params = self.func_params.get(callee).cloned();
                    for (i, a) in args.iter().enumerate() {
                        let v = self.compile_expr(a)?;
                        let v = match &params {
                            Some(ps) if i < ps.len() => {
                                if is_extern && ps[i] == Type::Str {
                                    self.str_ptr(v)?.into()
                                } else {
                                    let pt = self.type_to_basic(&ps[i])?;
                                    self.coerce(v, pt)
                                        .map_err(|e| format!("arg {} of {}: {}", i, callee, e))?
                                }
                            }
                            _ => v,
                        };
                        compiled.push(v.into());
                    }
                    let call = b!(self.builder.build_call(f, &compiled, "calltmp"));
                    match call.try_as_basic_value().basic() {
                        Some(v) => {
                            if is_extern && self.func_rets.get(callee) == Some(&Type::Str) {
                                let p = self.str_ptr(v)?;
                                Ok(self.make_str(p, 0))
                            } else {
                                Ok(v)
                            }
                        }
                        // void 调用：无值，返回占位 int（仅在语句位置使用）
                        None => Ok(self.context.i32_type().const_int(0, false).into()),
                    }
                }
                None if callee == "print" || callee == "println" => {
                    self.compile_builtin_print(callee, args)
                }
                None if callee.starts_with("volatile_store")
                    || callee.starts_with("volatile_load") =>
                {
                    self.compile_builtin_volatile(callee, args)
                }
                None if callee == "outb" || callee == "inb" || callee == "outl" || callee == "inl" => {
                    self.compile_builtin_io(callee, args)
                }
                None if callee == "cli" || callee == "sti" || callee == "hlt" => {
                    self.compile_builtin_naked(callee)
                }
                None if callee == "int_to_ptr" || callee == "ptr_to_int" => {
                    self.compile_builtin_cast(callee, args)
                }
                None if callee == "len" => self.compile_builtin_len(args),
                None if callee == "atomic_xchg" => self.compile_builtin_atomic_xchg(args),
                None => {
                    if let Some(Type::Fn(params, ret)) = self.var_types.get(callee).cloned() {
                        return self.compile_indirect_call(callee, &params, &ret, args);
                    }
                    Err(format!("unknown function '{}'", callee))
                }
            },
            Expr::StructInit { name, fields } => {
                let st = self
                    .struct_types
                    .get(name)
                    .copied()
                    .ok_or_else(|| format!("unknown struct '{}'", name))?;
                let field_list = self
                    .struct_defs
                    .get(name)
                    .ok_or_else(|| format!("unknown struct '{}'", name))?;
                let mut agg: AggregateValueEnum<'ctx> = st.const_zero().into();
                for (fname, fexpr) in fields {
                    let idx = field_list
                        .iter()
                        .position(|(n, _)| n == fname)
                        .ok_or_else(|| {
                            format!("struct '{}' has no field '{}'", name, fname)
                        })? as u32;
                    let val = self.compile_expr(fexpr)?;
                    agg = b!(self
                        .builder
                        .build_insert_value(agg, val, idx, "inserttmp"));
                }
                Ok(agg.as_basic_value_enum())
            }
            Expr::Field { base, field } => {
                let base_val = self.compile_expr(base)?;
                let sv = match base_val {
                    BasicValueEnum::StructValue(sv) => sv,
                    _ => return Err("field access requires a struct value".to_string()),
                };
                let name = self
                    .struct_name_for_type(sv.get_type())
                    .ok_or_else(|| "unknown struct type".to_string())?;
                let field_list = &self.struct_defs[&name];
                let idx = field_list
                    .iter()
                    .position(|(n, _)| n == field)
                    .ok_or_else(|| {
                        format!("struct '{}' has no field '{}'", name, field)
                    })? as u32;
                Ok(b!(self.builder.build_extract_value(sv, idx, "fieldtmp")))
            }
            Expr::Index { .. } => {
                let (ptr, elem_ty) = self.compile_lvalue_addr(expr)?;
                Ok(b!(self.builder.build_load(elem_ty, ptr, "idxload")))
            }
            Expr::Slice { base, lo, hi } => {
                let bv = self.compile_expr(base)?;
                let len = self.str_len(bv)?;
                let ptr = self.str_ptr(bv)?;
                let i64ty = self.context.i64_type();
                let coerce_idx = |v: BasicValueEnum<'ctx>| -> Result<IntValue<'ctx>, String> {
                    match v {
                        BasicValueEnum::IntValue(_) => {
                            match self.coerce(v, i64ty.into())? {
                                BasicValueEnum::IntValue(iv) => Ok(iv),
                                _ => Err("slice index must be int".to_string()),
                            }
                        }
                        _ => Err("slice index must be int".to_string()),
                    }
                };
                let lo_i = match lo {
                    Some(e) => coerce_idx(self.compile_expr(e)?)?,
                    None => i64ty.const_int(0, false),
                };
                let hi_i = match hi {
                    Some(e) => coerce_idx(self.compile_expr(e)?)?,
                    None => len,
                };
                let new_len = b!(self.builder.build_int_sub(hi_i, lo_i, "slicelen"));
                let gep = b!(unsafe {
                    self.builder.build_gep(self.context.i8_type(), ptr, &[lo_i], "sliceptr")
                });
                Ok(self.make_str_v(gep, new_len))
            }
            Expr::ArrayLit(elems) => {
                if elems.is_empty() {
                    return Err("empty array literal needs an explicit type".to_string());
                }
                let elem_ty = self.typeof_expr(&elems[0]);
                let elem_basic = self.type_to_basic(&elem_ty)?;
                let arr_ty = elem_basic.array_type(elems.len() as u32);
                let mut agg: AggregateValueEnum<'ctx> = arr_ty.const_zero().into();
                for (i, e) in elems.iter().enumerate() {
                    let v = self.compile_expr(e)?;
                    agg = b!(self
                        .builder
                        .build_insert_value(agg, v, i as u32, "arrlit"));
                }
                Ok(agg.as_basic_value_enum())
            }
            Expr::AddrOf(e) => {
                if let Expr::Var(name) = e.as_ref() {
                    if self.func_rets.contains_key(name) {
                        let f = self
                            .module
                            .get_function(name)
                            .ok_or_else(|| format!("unknown function '{}'", name))?;
                        let ptr = f.as_global_value().as_pointer_value();
                        let i64v = b!(self
                            .builder
                            .build_ptr_to_int(ptr, self.context.i64_type(), "fnaddr"));
                        return Ok(i64v.into());
                    }
                }
                let (ptr, _) = self.compile_lvalue_addr(e)?;
                Ok(ptr.into())
            }
            Expr::Cast { expr, ty } => {
                let v = self.compile_expr(expr)?;
                self.compile_cast(v, ty)
            }
            Expr::Deref(e) => {
                let ptr = self.compile_expr(e)?;
                let ptr_val = match ptr {
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err("deref requires a pointer".to_string()),
                };
                let pointee = match self.typeof_expr(e) {
                    Type::Ptr(t) => *t,
                    Type::Str => Type::U8,
                    _ => return Err("deref requires a pointer".to_string()),
                };
                let elem_ty = self.type_to_basic(&pointee)?;
                Ok(b!(self.builder.build_load(elem_ty, ptr_val, "deref")))
            }
        }
    }

    /// 计算表达式类型（用于指针解引用/下标/算术）。
    fn typeof_expr(&self, expr: &Expr) -> Type {
        match expr {
            Expr::Int(_) => Type::Int,
            Expr::Float(_) => Type::Float,
            Expr::Bool(_) => Type::Bool,
            Expr::Str(_) => Type::Str,
            Expr::Var(name) => self.var_types.get(name).cloned().unwrap_or(Type::Int),
            Expr::AddrOf(e) => {
                if let Expr::Var(name) = e.as_ref() {
                    if self.func_rets.contains_key(name) {
                        return Type::U64;
                    }
                }
                Type::Ptr(Box::new(self.typeof_expr(e)))
            }
            Expr::Deref(e) => match self.typeof_expr(e) {
                Type::Ptr(t) => *t,
                Type::Str => Type::U8,
                _ => Type::Int,
            },
            Expr::Index { base, .. } => match self.typeof_expr(base) {
                Type::Array(t, _) => *t,
                Type::Ptr(t) => *t,
                Type::Str => Type::U8,
                _ => Type::Int,
            },
            Expr::Slice { .. } => Type::Str,
            Expr::ArrayLit(elems) => {
                if elems.is_empty() {
                    Type::Int
                } else {
                    Type::Array(Box::new(self.typeof_expr(&elems[0])), elems.len())
                }
            }
            Expr::Binary { op, lhs, rhs } => {
                let lt = self.typeof_expr(lhs);
                let rt = self.typeof_expr(rhs);
                let is_u64 = lt == Type::U64 || rt == Type::U64;
                match op {
                    BinOp::Add | BinOp::Sub => {
                        if matches!(lt, Type::Ptr(_) | Type::Str) {
                            lt
                        } else if matches!(rt, Type::Ptr(_) | Type::Str) {
                            rt
                        } else if lt == Type::Float || rt == Type::Float {
                            Type::Float
                        } else if is_u64 {
                            Type::U64
                        } else {
                            Type::Int
                        }
                    }
                    BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Gt | BinOp::Le | BinOp::Ge => {
                        Type::Bool
                    }
                    _ => {
                        if lt == Type::Float || rt == Type::Float {
                            Type::Float
                        } else if is_u64 {
                            Type::U64
                        } else {
                            Type::Int
                        }
                    }
                }
            }
            Expr::Unary { op, expr } => match op {
                UnOp::Not => Type::Bool,
                UnOp::Neg => self.typeof_expr(expr),
                UnOp::BitNot => self.typeof_expr(expr),
            },
            Expr::Cast { ty, .. } => ty.clone(),
            Expr::Call { callee, .. } => match callee.as_str() {
                "int_to_ptr" => Type::Str,
                "ptr_to_int" => Type::U64,
                "volatile_load64" => Type::U64,
                _ => {
                    if let Some(Type::Fn(_, ret)) = self.var_types.get(callee) {
                        (**ret).clone()
                    } else {
                        self.func_rets.get(callee).cloned().unwrap_or(Type::Int)
                    }
                }
            },
            _ => Type::Int,
        }
    }

    /// 计算可赋值表达式（lvalue）的地址与元素类型。
    fn compile_lvalue_addr(
        &self,
        expr: &Expr,
    ) -> Result<(PointerValue<'ctx>, BasicTypeEnum<'ctx>), String> {
        match expr {
            Expr::Var(name) => {
                if let Some((ptr, ty)) = self.named_values.get(name).copied() {
                    Ok((ptr, ty))
                } else if let Some((gv, ty)) = self.globals.get(name).copied() {
                    Ok((gv.as_pointer_value(), ty))
                } else {
                    Err(format!("unknown variable '{}'", name))
                }
            }
            Expr::Index { base, index } => {
                let idx = self.compile_expr(index)?;
                let idx_i = match idx {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("array index must be int".to_string()),
                };
                match self.typeof_expr(base) {
                    Type::Array(_, _) => {
                        let (base_ptr, base_ty) = self.compile_lvalue_addr(base)?;
                        let at = match base_ty {
                            BasicTypeEnum::ArrayType(at) => at,
                            _ => return Err("indexing requires an array".to_string()),
                        };
                        let elem_ty = at.get_element_type();
                        let zero = self.context.i32_type().const_int(0, false);
                        let gep = b!(unsafe {
                            self.builder.build_gep(at, base_ptr, &[zero, idx_i], "gep")
                        });
                        Ok((gep, elem_ty))
                    }
                    Type::Ptr(inner) => {
                        let ptr_val = self.compile_expr(base)?;
                        let pv = match ptr_val {
                            BasicValueEnum::PointerValue(p) => p,
                            _ => return Err("pointer indexing requires a pointer".to_string()),
                        };
                        let elem_ty = self.type_to_basic(&inner)?;
                        let gep = b!(unsafe {
                            self.builder.build_gep(elem_ty, pv, &[idx_i], "gep")
                        });
                        Ok((gep, elem_ty))
                    }
                    Type::Str => {
                        let ptr_val = self.compile_expr(base)?;
                        let pv = self.str_ptr(ptr_val)?;
                        let elem_ty = self.context.i8_type();
                        let gep = b!(unsafe {
                            self.builder.build_gep(elem_ty, pv, &[idx_i], "gep")
                        });
                        Ok((gep, elem_ty.into()))
                    }
                    _ => Err("indexing requires an array or pointer".to_string()),
                }
            }
            Expr::Deref(e) => {
                let ptr = self.compile_expr(e)?;
                let ptr_val = match ptr {
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err("deref requires a pointer".to_string()),
                };
                let pointee = match self.typeof_expr(e) {
                    Type::Ptr(t) => *t,
                    Type::Str => Type::U8,
                    _ => return Err("deref requires a pointer".to_string()),
                };
                let elem_ty = self.type_to_basic(&pointee)?;
                Ok((ptr_val, elem_ty))
            }
            _ => Err("expression is not assignable".to_string()),
        }
    }

    fn get_printf(&self) -> FunctionValue<'ctx> {
        if let Some(f) = self.module.get_function("printf") {
            return f;
        }
        let i8_ptr = self.context.ptr_type(AddressSpace::default());
        let printf_type = self.context.i32_type().fn_type(&[i8_ptr.into()], true);
        self.module
            .add_function("printf", printf_type, Some(Linkage::External))
    }

    /// 内置 `print` / `println`：按实参类型选择格式串，调用 libc printf。
    fn compile_builtin_print(
        &self,
        callee: &str,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if args.len() != 1 {
            return Err(format!("{} takes exactly 1 argument", callee));
        }
        let val = self.compile_expr(&args[0])?;
        let i32ty = self.context.i32_type();
        let ptr_ty = self.context.ptr_type(AddressSpace::default());
        let (fmt, extra): (String, Vec<BasicValueEnum<'ctx>>) = match val {
            BasicValueEnum::IntValue(iv) => {
                if iv.get_type().get_bit_width() == 1 {
                    let i32v = b!(self.builder.build_int_z_extend(iv, i32ty, "booli32"));
                    ("%d".to_string(), vec![i32v.into()])
                } else {
                    ("%d".to_string(), vec![val])
                }
            }
            BasicValueEnum::FloatValue(_) => ("%g".to_string(), vec![val]),
            BasicValueEnum::PointerValue(_) => ("%s".to_string(), vec![val]),
            BasicValueEnum::StructValue(sv) => {
                let p = match b!(self.builder.build_extract_value(sv, 0, "strptr")) {
                    BasicValueEnum::IntValue(iv) => {
                        b!(self.builder.build_int_to_ptr(iv, ptr_ty, "strptr2"))
                    }
                    BasicValueEnum::PointerValue(p) => p,
                    _ => return Err(format!("{}: unsupported argument type", callee)),
                };
                let len_i64 = match b!(self.builder.build_extract_value(sv, 1, "strlen")) {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err(format!("{}: unsupported argument type", callee)),
                };
                let len_i32 = b!(self.builder.build_int_truncate(len_i64, i32ty, "strlen32"));
                ("%.*s".to_string(), vec![len_i32.into(), p.into()])
            }
            _ => return Err(format!("{}: unsupported argument type", callee)),
        };

        let fmt_str = if callee == "println" {
            format!("{}\n", fmt)
        } else {
            fmt
        };
        let fmt_global = b!(self.builder.build_global_string_ptr(&fmt_str, "fmt"));
        let printf_fn = self.get_printf();
        let mut call_args: Vec<BasicMetadataValueEnum<'ctx>> =
            Vec::with_capacity(extra.len() + 1);
        call_args.push(fmt_global.as_pointer_value().into());
        for e in extra {
            call_args.push(e.into());
        }
        let call = b!(self.builder.build_call(printf_fn, &call_args, "printf"));
        Ok(call
            .try_as_basic_value()
            .basic()
            .unwrap_or_else(|| self.context.i32_type().const_int(0, false).into()))
    }

    /// 内置 volatile 内存访问：`volatile_store8/16/32(addr, val)`、`volatile_load8/16/32(addr)`。
    /// 地址与值都用 int 表示，内部做 int→ptr 与截断/零扩展。
    fn compile_builtin_volatile(
        &self,
        callee: &str,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let is_store = callee.starts_with("volatile_store");
        let width: u32 = match callee {
            "volatile_store8" | "volatile_load8" => 8,
            "volatile_store16" | "volatile_load16" => 16,
            "volatile_store32" | "volatile_load32" => 32,
            "volatile_store64" | "volatile_load64" => 64,
            _ => return Err(format!("unknown builtin '{}'", callee)),
        };
        let int_ty = match width {
            8 => self.context.i8_type(),
            16 => self.context.i16_type(),
            32 => self.context.i32_type(),
            _ => self.context.i64_type(),
        };
        let ptr_ty = self.context.ptr_type(AddressSpace::default());

        if is_store {
            if args.len() != 2 {
                return Err(format!("{} takes 2 arguments (addr, value)", callee));
            }
            let addr = self.compile_expr(&args[0])?;
            let val = self.compile_expr(&args[1])?;
            let addr_i = match addr {
                BasicValueEnum::IntValue(iv) => iv,
                _ => return Err("volatile address must be int".to_string()),
            };
            let val_i = match val {
                BasicValueEnum::IntValue(iv) => iv,
                _ => return Err("volatile value must be int".to_string()),
            };
            let ptr = b!(self.builder.build_int_to_ptr(addr_i, ptr_ty, "addrptr"));
            let store_val: BasicValueEnum<'ctx> = if width == 32 || width == 64 {
                val_i.into()
            } else {
                b!(self.builder.build_int_truncate(val_i, int_ty, "trunc")).into()
            };
            let store = b!(self.builder.build_store(ptr, store_val));
            store.set_volatile(true).map_err(|e| e.to_string())?;
            Ok(self.context.i32_type().const_int(0, false).into())
        } else {
            if args.len() != 1 {
                return Err(format!("{} takes 1 argument (addr)", callee));
            }
            let addr = self.compile_expr(&args[0])?;
            let addr_i = match addr {
                BasicValueEnum::IntValue(iv) => iv,
                _ => return Err("volatile address must be int".to_string()),
            };
            let ptr = b!(self.builder.build_int_to_ptr(addr_i, ptr_ty, "addrptr"));
            let load = b!(self.builder.build_load(int_ty, ptr, "loadtmp"));
            if let Some(inst) = load.as_instruction_value() {
                inst.set_volatile(true).map_err(|e| e.to_string())?;
            }
            let iv = match load {
                BasicValueEnum::IntValue(iv) => iv,
                _ => return Err("volatile load must be int".to_string()),
            };
            if width == 32 || width == 64 {
                Ok(iv.into())
            } else {
                Ok(b!(self
                    .builder
                    .build_int_z_extend(iv, self.context.i32_type(), "zext"))
                .into())
            }
        }
    }

    /// 内置 IO 端口访问：`outb(port, value)`、`inb(port) -> int`（x86 out/in 指令）。
    fn compile_builtin_io(
        &self,
        callee: &str,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        match callee {
            "outb" => {
                if args.len() != 2 {
                    return Err("outb(port, value) takes 2 arguments".to_string());
                }
                let port = self.compile_expr(&args[0])?;
                let val = self.compile_expr(&args[1])?;
                let port_i = match port {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("outb port must be int".to_string()),
                };
                let val_i = match val {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("outb value must be int".to_string()),
                };
                let port16 =
                    b!(self.builder.build_int_truncate(port_i, self.context.i16_type(), "port16"));
                let val8 =
                    b!(self.builder.build_int_truncate(val_i, self.context.i8_type(), "val8"));
                let fn_type = self.context.void_type().fn_type(
                    &[self.context.i16_type().into(), self.context.i8_type().into()],
                    false,
                );
                let asm = self.context.create_inline_asm(
                    fn_type,
                    "outb %al, %dx".to_string(),
                    "{dx},{ax},~{dirflag},~{fpsr},~{flags}".to_string(),
                    true,
                    false,
                    None,
                    false,
                );
                let params: [BasicMetadataValueEnum<'ctx>; 2] = [port16.into(), val8.into()];
                b!(self.builder.build_indirect_call(fn_type, asm, &params, "outb"));
                Ok(self.context.i32_type().const_int(0, false).into())
            }
            "inb" => {
                if args.len() != 1 {
                    return Err("inb(port) takes 1 argument".to_string());
                }
                let port = self.compile_expr(&args[0])?;
                let port_i = match port {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("inb port must be int".to_string()),
                };
                let port16 =
                    b!(self.builder.build_int_truncate(port_i, self.context.i16_type(), "port16"));
                let fn_type = self.context.i8_type().fn_type(&[self.context.i16_type().into()], false);
                let asm = self.context.create_inline_asm(
                    fn_type,
                    "inb %dx, %al".to_string(),
                    "={ax},{dx},~{dirflag},~{fpsr},~{flags}".to_string(),
                    true,
                    false,
                    None,
                    false,
                );
                let params: [BasicMetadataValueEnum<'ctx>; 1] = [port16.into()];
                let call = b!(self.builder.build_indirect_call(fn_type, asm, &params, "inb"));
                let iv = match call.try_as_basic_value().basic() {
                    Some(BasicValueEnum::IntValue(iv)) => iv,
                    _ => return Err("inb should return int".to_string()),
                };
                Ok(b!(self
                    .builder
                    .build_int_z_extend(iv, self.context.i32_type(), "zext"))
                .into())
            }
            "outl" => {
                if args.len() != 2 {
                    return Err("outl(port, value) takes 2 arguments".to_string());
                }
                let port = self.compile_expr(&args[0])?;
                let val = self.compile_expr(&args[1])?;
                let port_i = match port {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("outl port must be int".to_string()),
                };
                let val_i = match val {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("outl value must be int".to_string()),
                };
                let port16 =
                    b!(self.builder.build_int_truncate(port_i, self.context.i16_type(), "port16"));
                let fn_type = self.context.void_type().fn_type(
                    &[self.context.i16_type().into(), self.context.i32_type().into()],
                    false,
                );
                let asm = self.context.create_inline_asm(
                    fn_type,
                    "outl %eax, %dx".to_string(),
                    "{dx},{ax},~{dirflag},~{fpsr},~{flags}".to_string(),
                    true,
                    false,
                    None,
                    false,
                );
                let params: [BasicMetadataValueEnum<'ctx>; 2] = [port16.into(), val_i.into()];
                b!(self.builder.build_indirect_call(fn_type, asm, &params, "outl"));
                Ok(self.context.i32_type().const_int(0, false).into())
            }
            "inl" => {
                if args.len() != 1 {
                    return Err("inl(port) takes 1 argument".to_string());
                }
                let port = self.compile_expr(&args[0])?;
                let port_i = match port {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("inl port must be int".to_string()),
                };
                let port16 =
                    b!(self.builder.build_int_truncate(port_i, self.context.i16_type(), "port16"));
                let fn_type = self.context.i32_type().fn_type(&[self.context.i16_type().into()], false);
                let asm = self.context.create_inline_asm(
                    fn_type,
                    "inl %dx, %eax".to_string(),
                    "={ax},{dx},~{dirflag},~{fpsr},~{flags}".to_string(),
                    true,
                    false,
                    None,
                    false,
                );
                let params: [BasicMetadataValueEnum<'ctx>; 1] = [port16.into()];
                let call = b!(self.builder.build_indirect_call(fn_type, asm, &params, "inl"));
                match call.try_as_basic_value().basic() {
                    Some(BasicValueEnum::IntValue(iv)) => Ok(iv.into()),
                    _ => Err("inl should return int".to_string()),
                }
            }
            _ => Err(format!("unknown io builtin '{}'", callee)),
        }
    }

    /// 内置指针转换：`int_to_ptr(addr) -> str`、`ptr_to_int(p) -> u64`。
    /// 地址通道为 64 位（不再截断 i32）：内核低地址经 coerce 截断无损，宿主高地址完整保留。
    fn compile_builtin_cast(
        &self,
        callee: &str,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if args.len() != 1 {
            return Err(format!("{} takes 1 argument", callee));
        }
        let v = self.compile_expr(&args[0])?;
        match callee {
            "int_to_ptr" => {
                let iv = match v {
                    BasicValueEnum::IntValue(iv) => iv,
                    _ => return Err("int_to_ptr requires an int".to_string()),
                };
                let ptr_ty = self.context.ptr_type(AddressSpace::default());
                let ptr = b!(self.builder.build_int_to_ptr(iv, ptr_ty, "inttoptr"));
                Ok(self.make_str(ptr, 0))
            }
            "ptr_to_int" => {
                let ptr = self.str_ptr(v)?;
                let i64v = b!(self
                    .builder
                    .build_ptr_to_int(ptr, self.context.i64_type(), "ptrtoint"));
                Ok(i64v.into())
            }
            _ => Err(format!("unknown cast '{}'", callee)),
        }
    }

    /// 内置 `len(x)`：str 返回运行时长度（i64），数组返回编译期长度。
    fn compile_builtin_len(
        &self,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if args.len() != 1 {
            return Err("len() takes 1 argument".to_string());
        }
        match self.typeof_expr(&args[0]) {
            Type::Str => {
                let v = self.compile_expr(&args[0])?;
                let iv = self.str_len(v)?;
                Ok(iv.into())
            }
            Type::Array(_, n) => {
                Ok(self.context.i64_type().const_int(n as u64, false).into())
            }
            _ => Err(format!("len() unsupported for {:?}", self.typeof_expr(&args[0]))),
        }
    }

    /// 内置原子交换：`atomic_xchg(addr, value) -> int`（xchg，返回旧值，自旋锁用）。
    fn compile_builtin_atomic_xchg(
        &self,
        args: &[Expr],
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if args.len() != 2 {
            return Err("atomic_xchg(addr, value) takes 2 arguments".to_string());
        }
        let addr = self.compile_expr(&args[0])?;
        let val = self.compile_expr(&args[1])?;
        let addr_i = match addr {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("atomic_xchg address must be int".to_string()),
        };
        let val_i = match val {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("atomic_xchg value must be int".to_string()),
        };
        let ptr_ty = self.context.ptr_type(AddressSpace::default());
        let ptr = b!(self.builder.build_int_to_ptr(addr_i, ptr_ty, "lockptr"));
        let old = b!(self
            .builder
            .build_atomicrmw(AtomicRMWBinOp::Xchg, ptr, val_i, AtomicOrdering::SequentiallyConsistent));
        Ok(old.into())
    }

    /// 内置裸指令：`cli` / `sti` / `hlt`（无操作数内联汇编）。
    fn compile_builtin_naked(&self, callee: &str) -> Result<BasicValueEnum<'ctx>, String> {
        let asm_str = match callee {
            "cli" => "cli",
            "sti" => "sti",
            "hlt" => "hlt",
            _ => return Err(format!("unknown naked builtin '{}'", callee)),
        };
        let fn_type = self.context.void_type().fn_type(&[], false);
        let asm = self.context.create_inline_asm(
            fn_type,
            asm_str.to_string(),
            "~{dirflag},~{fpsr},~{flags}".to_string(),
            true,
            false,
            None,
            false,
        );
        let params: [BasicMetadataValueEnum<'ctx>; 0] = [];
        b!(self.builder.build_indirect_call(fn_type, asm, &params, callee));
        Ok(self.context.i32_type().const_int(0, false).into())
    }

    /// 显式 cast：`x as T`（int 收窄/拓宽、int↔float、int↔指针）。
    fn compile_cast(
        &self,
        v: BasicValueEnum<'ctx>,
        target: &Type,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let target_basic = self.type_to_basic(target)?;
        if v.get_type() == target_basic {
            return Ok(v);
        }
        match v {
            BasicValueEnum::IntValue(iv) => match target_basic {
                BasicTypeEnum::IntType(it) => {
                    let w = it.get_bit_width();
                    let sw = iv.get_type().get_bit_width();
                    if sw > w {
                        Ok(b!(self.builder.build_int_truncate(iv, it, "cast")).into())
                    } else {
                        Ok(b!(self.builder.build_int_z_extend(iv, it, "cast")).into())
                    }
                }
                BasicTypeEnum::FloatType(ft) => {
                    Ok(b!(self.builder.build_signed_int_to_float(iv, ft, "cast")).into())
                }
                BasicTypeEnum::PointerType(pt) => {
                    Ok(b!(self.builder.build_int_to_ptr(iv, pt, "cast")).into())
                }
                _ => Err("invalid cast".to_string()),
            },
            BasicValueEnum::FloatValue(fv) => match target_basic {
                BasicTypeEnum::IntType(it) => {
                    Ok(b!(self.builder.build_float_to_signed_int(fv, it, "cast")).into())
                }
                BasicTypeEnum::FloatType(_) => Ok(v),
                _ => Err("invalid cast".to_string()),
            },
            BasicValueEnum::PointerValue(pv) => match target_basic {
                BasicTypeEnum::IntType(it) => {
                    Ok(b!(self.builder.build_ptr_to_int(pv, it, "cast")).into())
                }
                BasicTypeEnum::PointerType(_) => Ok(v),
                _ => Err("invalid cast".to_string()),
            },
            _ => Err("invalid cast".to_string()),
        }
    }

    fn compile_unary(&self, op: UnOp, v: BasicValueEnum<'ctx>) -> Result<BasicValueEnum<'ctx>, String> {
        match op {
            UnOp::Neg => match v {
                BasicValueEnum::IntValue(iv) => Ok(b!(self.builder.build_int_neg(iv, "negtmp")).into()),
                BasicValueEnum::FloatValue(fv) => {
                    Ok(b!(self.builder.build_float_neg(fv, "negtmp")).into())
                }
                _ => Err("cannot negate non-numeric value".to_string()),
            },
            UnOp::Not => match v {
                BasicValueEnum::IntValue(iv) => {
                    if iv.get_type().get_bit_width() == 1 {
                        Ok(b!(self.builder.build_not(iv, "nottmp")).into())
                    } else {
                        Ok(b!(self.builder.build_int_compare(
                            IntPredicate::EQ,
                            iv,
                            self.context.i32_type().const_int(0, false),
                            "nottmp",
                        ))
                        .into())
                    }
                }
                _ => Err("cannot apply '!' to non-int value".to_string()),
            },
            UnOp::BitNot => match v {
                BasicValueEnum::IntValue(iv) => {
                    Ok(b!(self.builder.build_not(iv, "bittmp")).into())
                }
                _ => Err("cannot apply '~' to non-int value".to_string()),
            },
        }
    }

    /// 指针算术：p + i / i + p / p - i（按元素步进）。
    fn compile_ptr_arith(
        &self,
        op: BinOp,
        ptr_expr: &Expr,
        int_expr: &Expr,
        ptr_on_left: bool,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        if op == BinOp::Sub && !ptr_on_left {
            return Err("invalid pointer arithmetic (int - pointer)".to_string());
        }
        let ptr = self.compile_expr(ptr_expr)?;
        let int = self.compile_expr(int_expr)?;
        let pv = self.str_ptr(ptr)?;
        let mut iv = match int {
            BasicValueEnum::IntValue(iv) => iv,
            _ => return Err("pointer arithmetic requires an int".to_string()),
        };
        let pointee = match self.typeof_expr(ptr_expr) {
            Type::Ptr(t) => *t,
            Type::Str => Type::U8,
            _ => return Err("not a pointer".to_string()),
        };
        let elem_ty = self.type_to_basic(&pointee)?;
        if op == BinOp::Sub {
            iv = b!(self.builder.build_int_neg(iv, "negidx"));
        }
        let gep = b!(unsafe { self.builder.build_gep(elem_ty, pv, &[iv], "ptrarith") });
        Ok(gep.into())
    }

    fn compile_binary(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        use BinOp::*;
        match op {
            Add | Sub | Mul | Div | Mod => self.compile_arith(op, l, r),
            Eq | Ne | Lt | Gt | Le | Ge => self.compile_cmp(op, l, r),
            And | Or => self.compile_logic(op, l, r),
            BitAnd | BitOr | BitXor => self.compile_bitwise(op, l, r),
            Shl | Shr => self.compile_shift(op, l, r),
            In => unreachable!("'in' handled in compile_expr"),
        }
    }

    fn compile_bitwise(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let (a, b) = match (l, r) {
            (BasicValueEnum::IntValue(a), BasicValueEnum::IntValue(b)) => {
                self.promote_int(a, b)?
            }
            _ => return Err("bitwise ops require int operands".to_string()),
        };
        let v = match op {
            BinOp::BitAnd => b!(self.builder.build_and(a, b, "andtmp")),
            BinOp::BitOr => b!(self.builder.build_or(a, b, "ortmp")),
            BinOp::BitXor => b!(self.builder.build_xor(a, b, "xortmp")),
            _ => unreachable!(),
        };
        Ok(v.into())
    }

    fn compile_shift(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        let (a, b) = match (l, r) {
            (BasicValueEnum::IntValue(a), BasicValueEnum::IntValue(b)) => {
                self.promote_int(a, b)?
            }
            _ => return Err("shift ops require int operands".to_string()),
        };
        let v = match op {
            BinOp::Shl => b!(self.builder.build_left_shift(a, b, "shltmp")),
            BinOp::Shr => b!(self.builder.build_right_shift(a, b, false, "shrtmp")),
            _ => unreachable!(),
        };
        Ok(v.into())
    }

    fn compile_arith(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        use BasicValueEnum::*;
        match (l, r) {
            (IntValue(a), IntValue(b)) => {
                let (a, b) = self.promote_int(a, b)?;
                let v = match op {
                    BinOp::Add => b!(self.builder.build_int_add(a, b, "addtmp")),
                    BinOp::Sub => b!(self.builder.build_int_sub(a, b, "subtmp")),
                    BinOp::Mul => b!(self.builder.build_int_mul(a, b, "multmp")),
                    BinOp::Div => b!(self.builder.build_int_signed_div(a, b, "divtmp")),
                    BinOp::Mod => b!(self.builder.build_int_signed_rem(a, b, "modtmp")),
                    _ => unreachable!(),
                };
                Ok(v.into())
            }
            (FloatValue(a), FloatValue(b)) => {
                let v = match op {
                    BinOp::Add => b!(self.builder.build_float_add(a, b, "addtmp")),
                    BinOp::Sub => b!(self.builder.build_float_sub(a, b, "subtmp")),
                    BinOp::Mul => b!(self.builder.build_float_mul(a, b, "multmp")),
                    BinOp::Div => b!(self.builder.build_float_div(a, b, "divtmp")),
                    BinOp::Mod => b!(self.builder.build_float_rem(a, b, "modtmp")),
                    _ => unreachable!(),
                };
                Ok(v.into())
            }
            _ => Err("type mismatch: arithmetic requires matching int/float".to_string()),
        }
    }

    fn compile_cmp(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        use BasicValueEnum::*;
        match (l, r) {
            (IntValue(a), IntValue(b)) => {
                let (a, b) = self.promote_int(a, b)?;
                let pred = match op {
                    BinOp::Eq => IntPredicate::EQ,
                    BinOp::Ne => IntPredicate::NE,
                    BinOp::Lt => IntPredicate::SLT,
                    BinOp::Gt => IntPredicate::SGT,
                    BinOp::Le => IntPredicate::SLE,
                    BinOp::Ge => IntPredicate::SGE,
                    _ => unreachable!(),
                };
                Ok(b!(self.builder.build_int_compare(pred, a, b, "cmptmp")).into())
            }
            (FloatValue(a), FloatValue(b)) => {
                let pred = match op {
                    BinOp::Eq => FloatPredicate::OEQ,
                    BinOp::Ne => FloatPredicate::ONE,
                    BinOp::Lt => FloatPredicate::OLT,
                    BinOp::Gt => FloatPredicate::OGT,
                    BinOp::Le => FloatPredicate::OLE,
                    BinOp::Ge => FloatPredicate::OGE,
                    _ => unreachable!(),
                };
                Ok(b!(self.builder.build_float_compare(pred, a, b, "cmptmp")).into())
            }
            (PointerValue(a), PointerValue(b)) => {
                // 指针 ==/!= 指针
                let pred = match op {
                    BinOp::Eq => IntPredicate::EQ,
                    BinOp::Ne => IntPredicate::NE,
                    _ => return Err("only == and != are defined for pointers".to_string()),
                };
                let ai = b!(self
                    .builder
                    .build_ptr_to_int(a, self.context.i64_type(), "ptrcmp"));
                let bi = b!(self
                    .builder
                    .build_ptr_to_int(b, self.context.i64_type(), "ptrcmp"));
                Ok(b!(self.builder.build_int_compare(pred, ai, bi, "cmptmp")).into())
            }
            (PointerValue(a), IntValue(b)) => {
                // 指针 == int（判空 p == 0）
                let pred = match op {
                    BinOp::Eq => IntPredicate::EQ,
                    BinOp::Ne => IntPredicate::NE,
                    _ => return Err("only == and != are defined for pointers".to_string()),
                };
                let ai = b!(self
                    .builder
                    .build_ptr_to_int(a, self.context.i64_type(), "ptrcmp"));
                let bi = b!(self
                    .builder
                    .build_int_z_extend(b, self.context.i64_type(), "ptrcmp"));
                Ok(b!(self.builder.build_int_compare(pred, ai, bi, "cmptmp")).into())
            }
            (IntValue(a), PointerValue(b)) => {
                let pred = match op {
                    BinOp::Eq => IntPredicate::EQ,
                    BinOp::Ne => IntPredicate::NE,
                    _ => return Err("only == and != are defined for pointers".to_string()),
                };
                let ai = b!(self
                    .builder
                    .build_int_z_extend(a, self.context.i64_type(), "ptrcmp"));
                let bi = b!(self
                    .builder
                    .build_ptr_to_int(b, self.context.i64_type(), "ptrcmp"));
                Ok(b!(self.builder.build_int_compare(pred, ai, bi, "cmptmp")).into())
            }
            _ => Err("type mismatch: comparison requires matching int/float/pointer".to_string()),
        }
    }

    fn compile_logic(
        &self,
        op: BinOp,
        l: BasicValueEnum<'ctx>,
        r: BasicValueEnum<'ctx>,
    ) -> Result<BasicValueEnum<'ctx>, String> {
        use BasicValueEnum::*;
        match (l, r) {
            (IntValue(a), IntValue(b)) => {
                let v = match op {
                    BinOp::And => b!(self.builder.build_and(a, b, "andtmp")),
                    BinOp::Or => b!(self.builder.build_or(a, b, "ortmp")),
                    _ => unreachable!(),
                };
                Ok(v.into())
            }
            _ => Err("type mismatch: logical ops require bool operands".to_string()),
        }
    }
}
