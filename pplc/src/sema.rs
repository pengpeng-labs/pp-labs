//! 小型语义分析：在 LLVM codegen 前检查名字、作用域和基础类型规则。

use std::collections::{HashMap, HashSet};

use crate::ast::*;

#[derive(Clone)]
struct FunctionSig {
    params: Vec<Type>,
    ret: Type,
    variadic: bool,
}

pub fn check_program(items: &[Item]) -> Result<(), String> {
    let mut structs = HashMap::new();
    let mut enums: HashMap<String, Vec<EnumVariant>> = HashMap::new();
    let mut functions: HashMap<String, FunctionSig> = HashMap::new();
    let mut globals = HashMap::new();

    for item in items {
        match item {
            Item::Struct(def) => {
                if enums.contains_key(&def.name) {
                    return Err(format!("type '{}' is already defined", def.name));
                }
                if structs
                    .insert(def.name.clone(), def.fields.clone())
                    .is_some()
                {
                    return Err(format!("duplicate struct definition '{}'", def.name));
                }
            }
            Item::Enum(def) => {
                if structs.contains_key(&def.name) || enums.contains_key(&def.name) {
                    return Err(format!("type '{}' is already defined", def.name));
                }
                if def.variants.is_empty() {
                    return Err(format!("enum '{}' requires at least one variant", def.name));
                }
                let mut names = HashSet::new();
                for variant in &def.variants {
                    if !names.insert(variant.name.clone()) {
                        return Err(format!(
                            "duplicate enum variant '{}.{}'",
                            def.name, variant.name
                        ));
                    }
                }
                enums.insert(def.name.clone(), def.variants.clone());
            }
            Item::Extern(proto) | Item::Function(Function { proto, .. }) => {
                if matches!(item, Item::Extern(_))
                    && (contains_tuple(&proto.ret)
                        || proto.params.iter().any(|(_, ty)| contains_tuple(ty)))
                {
                    return Err(format!(
                        "extern function '{}' cannot use tuple types",
                        proto.name
                    ));
                }
                if matches!(item, Item::Extern(_)) && proto.ret == Type::Str {
                    return Err(format!(
                        "extern function '{}' cannot return str without a length; return *u8 and construct a view explicitly",
                        proto.name
                    ));
                }
                let sig = FunctionSig {
                    params: proto.params.iter().map(|(_, ty)| ty.clone()).collect(),
                    ret: proto.ret.clone(),
                    variadic: proto.is_var_arg,
                };
                if let Some(existing) = functions.get(&proto.name) {
                    if existing.params != sig.params || existing.ret != sig.ret {
                        return Err(format!("conflicting declaration for '{}'", proto.name));
                    }
                } else {
                    functions.insert(proto.name.clone(), sig);
                }
            }
            Item::Static(value) => {
                if globals
                    .insert(value.name.clone(), value.ty.clone())
                    .is_some()
                {
                    return Err(format!("duplicate static definition '{}'", value.name));
                }
            }
            Item::Import(_) => {}
        }
    }

    for fields in structs.values() {
        for (_, ty) in fields {
            check_type(ty, &structs, &enums)?;
        }
    }
    for variants in enums.values() {
        for variant in variants {
            if let Some(payload) = &variant.payload {
                check_type(payload, &structs, &enums)?;
            }
        }
    }
    for sig in functions.values() {
        for ty in &sig.params {
            check_type(ty, &structs, &enums)?;
        }
        check_type(&sig.ret, &structs, &enums)?;
    }
    for ty in globals.values() {
        check_type(ty, &structs, &enums)?;
    }

    for item in items {
        if let Item::Function(function) = item {
            Checker::new(&structs, &enums, &functions, &globals).check_function(function)?;
        }
    }
    Ok(())
}

fn check_type(
    ty: &Type,
    structs: &HashMap<String, Vec<(String, Type)>>,
    enums: &HashMap<String, Vec<EnumVariant>>,
) -> Result<(), String> {
    match ty {
        Type::Array(inner, _) | Type::Ptr(inner) => check_type(inner, structs, enums),
        Type::Tuple(elements) => {
            if elements.len() < 2 {
                return Err("tuple type requires at least two elements".to_string());
            }
            for element in elements {
                check_type(element, structs, enums)?;
            }
            Ok(())
        }
        Type::Fn(params, ret) => {
            for param in params {
                check_type(param, structs, enums)?;
            }
            check_type(ret, structs, enums)
        }
        Type::Named(name) if !structs.contains_key(name) && !enums.contains_key(name) => {
            Err(format!("unknown type '{}'", name))
        }
        _ => Ok(()),
    }
}

struct Checker<'a> {
    structs: &'a HashMap<String, Vec<(String, Type)>>,
    enums: &'a HashMap<String, Vec<EnumVariant>>,
    functions: &'a HashMap<String, FunctionSig>,
    globals: &'a HashMap<String, Type>,
    scopes: Vec<HashMap<String, Type>>,
    return_type: Type,
    loop_depth: usize,
}

impl<'a> Checker<'a> {
    fn new(
        structs: &'a HashMap<String, Vec<(String, Type)>>,
        enums: &'a HashMap<String, Vec<EnumVariant>>,
        functions: &'a HashMap<String, FunctionSig>,
        globals: &'a HashMap<String, Type>,
    ) -> Self {
        Self {
            structs,
            enums,
            functions,
            globals,
            scopes: Vec::new(),
            return_type: Type::Void,
            loop_depth: 0,
        }
    }

    fn check_function(&mut self, function: &Function) -> Result<(), String> {
        self.return_type = function.proto.ret.clone();
        self.scopes.push(HashMap::new());
        for (name, ty) in &function.proto.params {
            self.declare(name, ty.clone())?;
        }
        let result = self.check_statements(&function.body.stmts, false);
        self.scopes.pop();
        result.map_err(|error| format!("in function '{}': {}", function.proto.name, error))
    }

    fn check_statements(&mut self, statements: &[Stmt], scoped: bool) -> Result<(), String> {
        if scoped {
            self.scopes.push(HashMap::new());
        }
        let result = statements.iter().try_for_each(|stmt| self.check_stmt(stmt));
        if scoped {
            self.scopes.pop();
        }
        result
    }

    fn check_stmt(&mut self, stmt: &Stmt) -> Result<(), String> {
        match stmt {
            Stmt::Return(value) => match (value, self.return_type.clone()) {
                (None, Type::Void) => Ok(()),
                (None, expected) => Err(format!("return requires a {:?} value", expected)),
                (Some(_), Type::Void) => {
                    Err("cannot return a value from void function".to_string())
                }
                (Some(expr), expected) => {
                    let actual = self.expr_type(expr)?;
                    if assignable(&actual, &expected) {
                        Ok(())
                    } else {
                        Err(format!(
                            "return type mismatch: {:?} to {:?}",
                            actual, expected
                        ))
                    }
                }
            },
            Stmt::Expr(expr) => self.expr_type(expr).map(|_| ()),
            Stmt::Defer(expr) => self.expr_type(expr.as_ref()).map(|_| ()),
            Stmt::Let { name, ty, init } => {
                let actual = init.as_ref().map(|expr| self.expr_type(expr)).transpose()?;
                let declared = match (ty, actual) {
                    (Some(expected), Some(actual)) => {
                        if !assignable(&actual, expected) {
                            return Err(format!(
                                "let {} type mismatch: {:?} to {:?}",
                                name, actual, expected
                            ));
                        }
                        expected.clone()
                    }
                    (Some(expected), None) => expected.clone(),
                    (None, Some(actual)) => actual,
                    (None, None) => return Err("let requires a type or initializer".to_string()),
                };
                self.declare(name, declared)
            }
            Stmt::LetTuple { names, init } => match self.expr_type(init)? {
                Type::Tuple(elements) if elements.len() == names.len() => {
                    for (name, ty) in names.iter().zip(elements) {
                        self.declare(name, ty)?;
                    }
                    Ok(())
                }
                Type::Tuple(elements) => Err(format!(
                    "tuple binding has {} names for {} values",
                    names.len(),
                    elements.len()
                )),
                other => Err(format!(
                    "tuple binding requires tuple value, got {:?}",
                    other
                )),
            },
            Stmt::Assign { name, value } => {
                let expected = self.lookup(name)?;
                let actual = self.expr_type(value)?;
                if assignable(&actual, &expected) {
                    Ok(())
                } else {
                    Err(format!(
                        "assign {} type mismatch: {:?} to {:?}",
                        name, actual, expected
                    ))
                }
            }
            Stmt::AssignIndex { lhs, value } => {
                let expected = self.expr_type(lhs)?;
                let actual = self.expr_type(value)?;
                if assignable(&actual, &expected) {
                    Ok(())
                } else {
                    Err(format!(
                        "index assignment type mismatch: {:?} to {:?}",
                        actual, expected
                    ))
                }
            }
            Stmt::If { cond, then, els } => {
                self.require_bool(cond)?;
                self.check_statements(&then.stmts, true)?;
                if let Some(block) = els {
                    self.check_statements(&block.stmts, true)?;
                }
                Ok(())
            }
            Stmt::While { cond, body } => {
                self.require_bool(cond)?;
                self.loop_depth += 1;
                let result = self.check_statements(&body.stmts, true);
                self.loop_depth -= 1;
                result
            }
            Stmt::For { var, iter, body } => {
                let iter_type = self.expr_type(iter)?;
                let element = match (&iter_type, iter) {
                    (Type::Array(element, _), _) => (**element).clone(),
                    (_, Expr::Call { callee, args, .. })
                        if callee == "range" && args.len() == 1 =>
                    {
                        Type::Int
                    }
                    _ => return Err("for loop requires an array or range(n)".to_string()),
                };
                self.scopes.push(HashMap::new());
                self.declare(var, element)?;
                self.loop_depth += 1;
                let result = self.check_statements(&body.stmts, false);
                self.loop_depth -= 1;
                self.scopes.pop();
                result
            }
            Stmt::Switch { expr, arms } => self.check_switch(expr, arms),
            Stmt::Break | Stmt::Continue if self.loop_depth == 0 => {
                Err("loop control outside loop".to_string())
            }
            Stmt::Break | Stmt::Continue => Ok(()),
        }
    }

    fn check_switch(&mut self, expr: &Expr, arms: &[SwitchArm]) -> Result<(), String> {
        let enum_name = match self.expr_type(expr)? {
            Type::Named(name) if self.enums.contains_key(&name) => name,
            other => return Err(format!("switch requires an enum value, got {:?}", other)),
        };
        let variants = self.enums[&enum_name].clone();
        let mut seen = HashSet::new();
        let mut wildcard = false;

        for (index, arm) in arms.iter().enumerate() {
            self.scopes.push(HashMap::new());
            let result = (|| match &arm.pattern {
                SwitchPattern::Wildcard => {
                    if wildcard {
                        Err("duplicate wildcard switch arm".to_string())
                    } else if index + 1 != arms.len() {
                        Err("wildcard switch arm must be last".to_string())
                    } else {
                        wildcard = true;
                        self.check_statements(&arm.body.stmts, false)
                    }
                }
                SwitchPattern::Variant {
                    enum_name: pattern_enum,
                    variant,
                    binding,
                } => {
                    if pattern_enum != &enum_name
                        && !crate::mono::instance_of(&enum_name, pattern_enum)
                    {
                        Err(format!(
                            "switch pattern '{}.{}' does not match enum '{}'",
                            pattern_enum, variant, enum_name
                        ))
                    } else if !seen.insert(variant.clone()) {
                        Err(format!("duplicate switch arm '{}.{}'", enum_name, variant))
                    } else {
                        let definition = variants
                            .iter()
                            .find(|candidate| candidate.name == *variant)
                            .ok_or_else(|| {
                                format!("enum '{}' has no variant '{}'", enum_name, variant)
                            })?;
                        match (&definition.payload, binding) {
                            (Some(payload), Some(name)) => self.declare(name, payload.clone())?,
                            (Some(_), None) => {
                                return Err(format!(
                                    "variant '{}.{}' requires a payload binding",
                                    enum_name, variant
                                ));
                            }
                            (None, Some(_)) => {
                                return Err(format!(
                                    "variant '{}.{}' has no payload",
                                    enum_name, variant
                                ));
                            }
                            (None, None) => {}
                        }
                        self.check_statements(&arm.body.stmts, false)
                    }
                }
            })();
            self.scopes.pop();
            result?;
        }

        if !wildcard {
            let missing: Vec<String> = variants
                .iter()
                .filter(|variant| !seen.contains(&variant.name))
                .map(|variant| format!("{}.{}", enum_name, variant.name))
                .collect();
            if !missing.is_empty() {
                return Err(format!(
                    "non-exhaustive switch: missing {}",
                    missing.join(", ")
                ));
            }
        }
        Ok(())
    }

    fn require_bool(&mut self, expr: &Expr) -> Result<(), String> {
        let ty = self.expr_type(expr)?;
        if ty == Type::Bool {
            Ok(())
        } else {
            Err(format!("condition must be bool, got {:?}", ty))
        }
    }

    fn expr_type(&mut self, expr: &Expr) -> Result<Type, String> {
        match expr {
            Expr::Int(_) => Ok(Type::Int),
            Expr::Float(_) => Ok(Type::Float),
            Expr::Bool(_) => Ok(Type::Bool),
            Expr::Str(_) => Ok(Type::Str),
            Expr::Var(name) => self.lookup(name),
            Expr::AddrOf(inner) => {
                if let Expr::Var(name) = inner.as_ref() {
                    if let Some(sig) = self.functions.get(name) {
                        return Ok(Type::Fn(sig.params.clone(), Box::new(sig.ret.clone())));
                    }
                }
                Ok(Type::Ptr(Box::new(self.expr_type(inner)?)))
            }
            Expr::Deref(inner) => match self.expr_type(inner)? {
                Type::Ptr(ty) => Ok(*ty),
                Type::Str => Ok(Type::U8),
                other => Err(format!("cannot dereference {:?}", other)),
            },
            Expr::Unary { op, expr } => {
                let ty = self.expr_type(expr)?;
                match op {
                    UnOp::Not if ty == Type::Bool => Ok(Type::Bool),
                    UnOp::Neg if numeric(&ty) => Ok(ty),
                    UnOp::BitNot if integer(&ty) => Ok(ty),
                    _ => Err(format!("invalid {:?} operand {:?}", op, ty)),
                }
            }
            Expr::Binary { op, lhs, rhs } => self.binary_type(*op, lhs, rhs),
            Expr::Call {
                callee,
                type_args,
                args,
            } if callee == "sizeof" || callee == "alignof" => {
                if type_args.len() != 1 || !args.is_empty() {
                    return Err(format!(
                        "{}[T]() requires exactly one type argument and no value arguments",
                        callee
                    ));
                }
                Ok(Type::U64)
            }
            Expr::Call { callee, args, .. } => self.call_type(callee, args),
            Expr::MethodCall {
                receiver,
                method,
                args,
                ..
            } => {
                if let Expr::Var(enum_name) = receiver.as_ref() {
                    if let Some(variants) = self.enums.get(enum_name) {
                        let variant = variants
                            .iter()
                            .find(|candidate| candidate.name == *method)
                            .ok_or_else(|| {
                                format!("enum '{}' has no variant '{}'", enum_name, method)
                            })?
                            .clone();
                        match (&variant.payload, args.as_slice()) {
                            (None, []) => return Ok(Type::Named(enum_name.clone())),
                            (Some(expected), [value]) => {
                                let actual = self.expr_type(value)?;
                                if assignable(&actual, expected) {
                                    return Ok(Type::Named(enum_name.clone()));
                                }
                                return Err(format!(
                                    "payload type mismatch for '{}.{}': {:?} to {:?}",
                                    enum_name, method, actual, expected
                                ));
                            }
                            (None, _) => {
                                return Err(format!(
                                    "variant '{}.{}' takes no payload",
                                    enum_name, method
                                ));
                            }
                            (Some(_), _) => {
                                return Err(format!(
                                    "variant '{}.{}' takes exactly one payload",
                                    enum_name, method
                                ));
                            }
                        }
                    }
                }
                let sig = self
                    .functions
                    .get(method)
                    .cloned()
                    .ok_or_else(|| format!("unknown method function '{}'", method))?;
                let first = sig
                    .params
                    .first()
                    .ok_or_else(|| format!("method function '{}' has no receiver", method))?;
                let receiver_ty = self.expr_type(receiver)?;
                let receiver_ok = assignable(&receiver_ty, first)
                    || matches!(first, Type::Ptr(inner) if **inner == receiver_ty);
                if !receiver_ok || args.len() + 1 != sig.params.len() {
                    return Err(format!("invalid receiver or arguments for '{}'", method));
                }
                for (arg, expected) in args.iter().zip(sig.params[1..].iter()) {
                    let actual = self.expr_type(arg)?;
                    if !assignable(&actual, expected) {
                        return Err(format!("invalid argument to method '{}'", method));
                    }
                }
                Ok(sig.ret)
            }
            Expr::StructInit { name, fields, .. } => {
                let definition = self
                    .structs
                    .get(name)
                    .ok_or_else(|| format!("unknown struct '{}'", name))?;
                for (field, value) in fields {
                    let expected = definition
                        .iter()
                        .find(|(candidate, _)| candidate == field)
                        .map(|(_, ty)| ty)
                        .ok_or_else(|| format!("struct '{}' has no field '{}'", name, field))?;
                    let actual = self.expr_type(value)?;
                    if !assignable(&actual, expected) {
                        return Err(format!(
                            "field {} type mismatch: {:?} to {:?}",
                            field, actual, expected
                        ));
                    }
                }
                Ok(Type::Named(name.clone()))
            }
            Expr::Field { base, field } => match self.expr_type(base)? {
                Type::Named(name) => self
                    .structs
                    .get(&name)
                    .and_then(|fields| fields.iter().find(|(candidate, _)| candidate == field))
                    .map(|(_, ty)| ty.clone())
                    .ok_or_else(|| format!("struct '{}' has no field '{}'", name, field)),
                Type::Ptr(inner) => match *inner {
                    Type::Named(name) => self
                        .structs
                        .get(&name)
                        .and_then(|fields| fields.iter().find(|(candidate, _)| candidate == field))
                        .map(|(_, ty)| ty.clone())
                        .ok_or_else(|| format!("struct '{}' has no field '{}'", name, field)),
                    other => Err(format!(
                        "field access requires struct, got pointer to {:?}",
                        other
                    )),
                },
                other => Err(format!("field access requires struct, got {:?}", other)),
            },
            Expr::Index { base, index } => {
                let index_ty = self.expr_type(index)?;
                if !integer(&index_ty) {
                    return Err("index must be an integer".to_string());
                }
                match self.expr_type(base)? {
                    Type::Array(element, _) | Type::Ptr(element) => Ok(*element),
                    Type::Str => Ok(Type::U8),
                    other => Err(format!("cannot index {:?}", other)),
                }
            }
            Expr::Slice { base, lo, hi } => {
                if self.expr_type(base)? != Type::Str {
                    return Err("slice base must be str".to_string());
                }
                for bound in [lo, hi].into_iter().flatten() {
                    if !integer(&self.expr_type(bound)?) {
                        return Err("slice bound must be an integer".to_string());
                    }
                }
                Ok(Type::Str)
            }
            Expr::ArrayLit(values) => {
                let first = values
                    .first()
                    .ok_or_else(|| "empty array literal requires a type".to_string())?;
                let element = self.expr_type(first)?;
                for value in &values[1..] {
                    let actual = self.expr_type(value)?;
                    if !assignable(&actual, &element) {
                        return Err("array literal elements must have one type".to_string());
                    }
                }
                Ok(Type::Array(Box::new(element), values.len()))
            }
            Expr::Tuple(values) => {
                let mut elements = Vec::with_capacity(values.len());
                for value in values {
                    elements.push(self.expr_type(value)?);
                }
                Ok(Type::Tuple(elements))
            }
            Expr::Cast { expr, ty } => {
                let source = self.expr_type(expr)?;
                if castable(&source, ty) {
                    Ok(ty.clone())
                } else {
                    Err(format!("invalid cast from {:?} to {:?}", source, ty))
                }
            }
        }
    }

    fn binary_type(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr) -> Result<Type, String> {
        let left = self.expr_type(lhs)?;
        let right = self.expr_type(rhs)?;
        match op {
            BinOp::And | BinOp::Or if left == Type::Bool && right == Type::Bool => Ok(Type::Bool),
            BinOp::And | BinOp::Or => Err("logical operands must be bool".to_string()),
            BinOp::Eq | BinOp::Ne if comparable(&left, &right) => Ok(Type::Bool),
            BinOp::Lt | BinOp::Gt | BinOp::Le | BinOp::Ge if numeric(&left) && numeric(&right) => {
                Ok(Type::Bool)
            }
            BinOp::In => match right {
                Type::Array(element, _) if assignable(&left, &element) => Ok(Type::Bool),
                Type::Str if integer(&left) => Ok(Type::Bool),
                _ => Err("invalid membership operands".to_string()),
            },
            BinOp::Add | BinOp::Sub
                if matches!(left, Type::Ptr(_) | Type::Str) && integer(&right) =>
            {
                Ok(left)
            }
            BinOp::Add if matches!(right, Type::Ptr(_) | Type::Str) && integer(&left) => Ok(right),
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod
                if numeric(&left) && numeric(&right) =>
            {
                Ok(common_numeric(&left, &right))
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr
                if integer(&left) && integer(&right) =>
            {
                Ok(common_numeric(&left, &right))
            }
            _ => Err(format!(
                "invalid {:?} operands {:?} and {:?}",
                op, left, right
            )),
        }
    }

    fn call_type(&mut self, callee: &str, args: &[Expr]) -> Result<Type, String> {
        if callee == "range" {
            if args.len() != 1 || !integer(&self.expr_type(&args[0])?) {
                return Err("range(n) requires one integer".to_string());
            }
            return Ok(Type::Int);
        }
        if let Some(ret) = builtin_return(callee) {
            for arg in args {
                self.expr_type(arg)?;
            }
            return Ok(ret);
        }
        if let Some(sig) = self.functions.get(callee).cloned() {
            if args.len() < sig.params.len() || (!sig.variadic && args.len() != sig.params.len()) {
                return Err(format!("wrong number of arguments to '{}'", callee));
            }
            for (index, expected) in sig.params.iter().enumerate() {
                let actual = self.expr_type(&args[index])?;
                if !assignable(&actual, expected) {
                    return Err(format!(
                        "argument {} of {}: {:?} to {:?}",
                        index, callee, actual, expected
                    ));
                }
            }
            for arg in &args[sig.params.len()..] {
                self.expr_type(arg)?;
            }
            return Ok(sig.ret);
        }
        match self.lookup(callee)? {
            Type::Fn(params, ret) => {
                if params.len() != args.len() {
                    return Err(format!("wrong number of arguments to '{}'", callee));
                }
                for (arg, expected) in args.iter().zip(params.iter()) {
                    let actual = self.expr_type(arg)?;
                    if !assignable(&actual, expected) {
                        return Err(format!("invalid argument to function pointer '{}'", callee));
                    }
                }
                Ok(*ret)
            }
            _ => Err(format!("unknown function '{}'", callee)),
        }
    }

    fn declare(&mut self, name: &str, ty: Type) -> Result<(), String> {
        let scope = self.scopes.last_mut().expect("scope");
        if scope.contains_key(name) {
            return Err(format!("duplicate variable '{}' in the same scope", name));
        }
        scope.insert(name.to_string(), ty);
        Ok(())
    }

    fn lookup(&self, name: &str) -> Result<Type, String> {
        self.scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
            .or_else(|| self.globals.get(name).cloned())
            .ok_or_else(|| format!("unknown variable '{}'", name))
    }
}

fn integer(ty: &Type) -> bool {
    matches!(ty, Type::Int | Type::U8 | Type::U16 | Type::U32 | Type::U64)
}

fn numeric(ty: &Type) -> bool {
    integer(ty) || *ty == Type::Float
}

fn assignable(source: &Type, target: &Type) -> bool {
    source == target
        || (integer(source) && integer(target))
        || match (source, target) {
            (Type::Fn(_, _), target) if integer(target) => true,
            (Type::Tuple(left), Type::Tuple(right)) if left.len() == right.len() => left
                .iter()
                .zip(right.iter())
                .all(|(source, target)| assignable(source, target)),
            _ => false,
        }
}

fn contains_tuple(ty: &Type) -> bool {
    match ty {
        Type::Tuple(_) => true,
        Type::Array(inner, _) | Type::Ptr(inner) => contains_tuple(inner),
        Type::Fn(params, ret) => params.iter().any(contains_tuple) || contains_tuple(ret),
        _ => false,
    }
}

fn comparable(left: &Type, right: &Type) -> bool {
    assignable(left, right)
        || assignable(right, left)
        || matches!(
            (left, right),
            (Type::Ptr(_), Type::Int) | (Type::Int, Type::Ptr(_))
        )
}

fn castable(source: &Type, target: &Type) -> bool {
    (numeric(source) && numeric(target))
        || matches!(source, Type::Ptr(_)) && integer(target)
        || integer(source) && matches!(target, Type::Ptr(_))
        || matches!((source, target), (Type::Ptr(_), Type::Ptr(_)))
}

fn common_numeric(left: &Type, right: &Type) -> Type {
    if *left == Type::Float || *right == Type::Float {
        return Type::Float;
    }
    let width = |ty: &Type| match ty {
        Type::U8 => 8,
        Type::U16 => 16,
        Type::Int | Type::U32 => 32,
        Type::U64 => 64,
        _ => 0,
    };
    let bits = width(left).max(width(right));
    let unsigned = !matches!(left, Type::Int) || !matches!(right, Type::Int);
    match (bits, unsigned) {
        (0..=8, true) => Type::U8,
        (9..=16, true) => Type::U16,
        (17..=32, true) => Type::U32,
        (_, true) => Type::U64,
        _ => Type::Int,
    }
}

fn builtin_return(name: &str) -> Option<Type> {
    match name {
        "print" | "println" | "outb" | "outl" | "cli" | "sti" | "hlt" => Some(Type::Int),
        "inb" | "volatile_load8" => Some(Type::U8),
        "volatile_load16" => Some(Type::U16),
        "inl" | "volatile_load32" | "atomic_xchg" | "rdtsc" => Some(Type::Int),
        "volatile_load64" | "ptr_to_int" => Some(Type::U64),
        "volatile_store8" | "volatile_store16" | "volatile_store32" | "volatile_store64" => {
            Some(Type::Int)
        }
        "int_to_ptr" => Some(Type::Str),
        "str_from_ptr" => Some(Type::Str),
        "str_ptr" => Some(Type::Ptr(Box::new(Type::U8))),
        "len" => Some(Type::U64),
        _ => None,
    }
}
