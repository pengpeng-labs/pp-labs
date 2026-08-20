//! 显式泛型单态化：把模板实例改写为现有后端可消费的普通 AST。

use std::collections::{HashMap, HashSet};

use crate::ast::*;

const MAX_INSTANCES: usize = 256;

pub fn monomorphize(items: Vec<Item>) -> Result<Vec<Item>, String> {
    let mut mono = Monomorphizer::new(&items)?;
    let mut output = Vec::new();

    for item in items {
        match item {
            Item::Function(mut function) if function.proto.type_params.is_empty() => {
                mono.rewrite_function(&mut function, &HashMap::new())?;
                output.push(Item::Function(function));
            }
            Item::Struct(def) if def.type_params.is_empty() => {
                output.push(Item::Struct(mono.rewrite_struct(def, &HashMap::new())?));
            }
            Item::Enum(def) if def.type_params.is_empty() => {
                output.push(Item::Enum(mono.rewrite_enum(def, &HashMap::new())?));
            }
            Item::Extern(proto) => {
                if !proto.type_params.is_empty() {
                    return Err(format!(
                        "extern function '{}' cannot be generic",
                        proto.name
                    ));
                }
                output.push(Item::Extern(proto));
            }
            Item::Static(mut value) => {
                value.ty = mono.rewrite_type(&value.ty, &HashMap::new())?;
                if let Some(init) = &mut value.init {
                    mono.rewrite_expr(init, &HashMap::new())?;
                }
                output.push(Item::Static(value));
            }
            Item::Import(path) => output.push(Item::Import(path)),
            Item::Function(_) | Item::Struct(_) | Item::Enum(_) => {}
        }
    }

    output.splice(0..0, mono.generated_types);
    output.extend(mono.generated_functions.into_iter().map(Item::Function));
    Ok(output)
}

struct Monomorphizer {
    function_templates: HashMap<String, Function>,
    struct_templates: HashMap<String, StructDef>,
    enum_templates: HashMap<String, EnumDef>,
    instantiated_functions: HashSet<String>,
    instantiated_types: HashSet<String>,
    active_functions: HashSet<String>,
    active_types: HashSet<String>,
    generated_functions: Vec<Function>,
    generated_types: Vec<Item>,
}

impl Monomorphizer {
    fn new(items: &[Item]) -> Result<Self, String> {
        let mut result = Self {
            function_templates: HashMap::new(),
            struct_templates: HashMap::new(),
            enum_templates: HashMap::new(),
            instantiated_functions: HashSet::new(),
            instantiated_types: HashSet::new(),
            active_functions: HashSet::new(),
            active_types: HashSet::new(),
            generated_functions: Vec::new(),
            generated_types: Vec::new(),
        };
        let mut function_definitions = HashSet::new();
        let mut type_definitions = HashSet::new();
        for item in items {
            match item {
                Item::Function(function) => {
                    if !function_definitions.insert(function.proto.name.clone()) {
                        return Err(format!(
                            "duplicate function definition '{}'",
                            function.proto.name
                        ));
                    }
                }
                Item::Struct(def) => {
                    if !type_definitions.insert(def.name.clone()) {
                        return Err(format!("type '{}' is already defined", def.name));
                    }
                }
                Item::Enum(def) => {
                    if !type_definitions.insert(def.name.clone()) {
                        return Err(format!("type '{}' is already defined", def.name));
                    }
                }
                _ => {}
            }
        }
        for item in items {
            match item {
                Item::Function(function) if !function.proto.type_params.is_empty() => {
                    validate_params(&function.proto.name, &function.proto.type_params)?;
                    result
                        .function_templates
                        .insert(function.proto.name.clone(), function.clone());
                }
                Item::Struct(def) if !def.type_params.is_empty() => {
                    validate_params(&def.name, &def.type_params)?;
                    result
                        .struct_templates
                        .insert(def.name.clone(), def.clone());
                }
                Item::Enum(def) if !def.type_params.is_empty() => {
                    validate_params(&def.name, &def.type_params)?;
                    result.enum_templates.insert(def.name.clone(), def.clone());
                }
                _ => {}
            }
        }
        for function in result.function_templates.values() {
            validate_generic_function(
                function,
                &result.enum_templates,
                &result.function_templates,
            )?;
        }
        Ok(result)
    }

    fn check_limit(&self) -> Result<(), String> {
        if self.instantiated_functions.len() + self.instantiated_types.len() > MAX_INSTANCES {
            Err(format!(
                "generic instantiation limit ({}) exceeded; possible recursive expansion",
                MAX_INSTANCES
            ))
        } else {
            Ok(())
        }
    }

    fn rewrite_type(&mut self, ty: &Type, subst: &HashMap<String, Type>) -> Result<Type, String> {
        match ty {
            Type::Named(name) => Ok(subst
                .get(name)
                .cloned()
                .unwrap_or_else(|| Type::Named(name.clone()))),
            Type::Applied(name, args) => {
                let args = args
                    .iter()
                    .map(|arg| self.rewrite_type(arg, subst))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Type::Named(self.instantiate_type(name, &args)?))
            }
            Type::Array(inner, len) => Ok(Type::Array(
                Box::new(self.rewrite_type(inner, subst)?),
                *len,
            )),
            Type::Ptr(inner) => Ok(Type::Ptr(Box::new(self.rewrite_type(inner, subst)?))),
            Type::Fn(params, ret) => Ok(Type::Fn(
                params
                    .iter()
                    .map(|param| self.rewrite_type(param, subst))
                    .collect::<Result<Vec<_>, _>>()?,
                Box::new(self.rewrite_type(ret, subst)?),
            )),
            Type::Tuple(elements) => Ok(Type::Tuple(
                elements
                    .iter()
                    .map(|element| self.rewrite_type(element, subst))
                    .collect::<Result<Vec<_>, _>>()?,
            )),
            other => Ok(other.clone()),
        }
    }

    fn instantiate_type(&mut self, name: &str, args: &[Type]) -> Result<String, String> {
        let params = if let Some(def) = self.struct_templates.get(name) {
            def.type_params.clone()
        } else if let Some(def) = self.enum_templates.get(name) {
            def.type_params.clone()
        } else {
            return Err(format!("'{}' is not a generic type", name));
        };
        check_arity(name, &params, args)?;
        let concrete_name = mangle(name, args);
        if !self.instantiated_types.insert(concrete_name.clone()) {
            return Ok(concrete_name);
        }
        if !self.active_types.insert(name.to_string()) {
            return Err(format!(
                "generic type '{}' recursively expands to a different instance",
                name
            ));
        }
        self.check_limit()?;
        let subst = params.into_iter().zip(args.iter().cloned()).collect();
        if let Some(template) = self.struct_templates.get(name).cloned() {
            let mut def = self.rewrite_struct(template, &subst)?;
            def.name = concrete_name.clone();
            def.type_params.clear();
            self.generated_types.push(Item::Struct(def));
        } else {
            let template = self.enum_templates[name].clone();
            let mut def = self.rewrite_enum(template, &subst)?;
            def.name = concrete_name.clone();
            def.type_params.clear();
            self.generated_types.push(Item::Enum(def));
        }
        self.active_types.remove(name);
        Ok(concrete_name)
    }

    fn instantiate_function(&mut self, name: &str, args: &[Type]) -> Result<String, String> {
        let template = self
            .function_templates
            .get(name)
            .cloned()
            .ok_or_else(|| format!("'{}' is not a generic function", name))?;
        check_arity(name, &template.proto.type_params, args)?;
        let concrete_name = mangle(name, args);
        if !self.instantiated_functions.insert(concrete_name.clone()) {
            return Ok(concrete_name);
        }
        if !self.active_functions.insert(name.to_string()) {
            return Err(format!(
                "generic function '{}' recursively expands to a different instance",
                name
            ));
        }
        self.check_limit()?;
        let subst = template
            .proto
            .type_params
            .iter()
            .cloned()
            .zip(args.iter().cloned())
            .collect();
        let mut function = template;
        function.proto.name = concrete_name.clone();
        function.proto.type_params.clear();
        self.rewrite_function(&mut function, &subst)?;
        self.generated_functions.push(function);
        self.active_functions.remove(name);
        Ok(concrete_name)
    }

    fn rewrite_struct(
        &mut self,
        mut def: StructDef,
        subst: &HashMap<String, Type>,
    ) -> Result<StructDef, String> {
        for (_, ty) in &mut def.fields {
            *ty = self.rewrite_type(ty, subst)?;
        }
        Ok(def)
    }

    fn rewrite_enum(
        &mut self,
        mut def: EnumDef,
        subst: &HashMap<String, Type>,
    ) -> Result<EnumDef, String> {
        for variant in &mut def.variants {
            if let Some(payload) = &mut variant.payload {
                *payload = self.rewrite_type(payload, subst)?;
            }
        }
        Ok(def)
    }

    fn rewrite_function(
        &mut self,
        function: &mut Function,
        subst: &HashMap<String, Type>,
    ) -> Result<(), String> {
        for (_, ty) in &mut function.proto.params {
            *ty = self.rewrite_type(ty, subst)?;
        }
        function.proto.ret = self.rewrite_type(&function.proto.ret, subst)?;
        self.rewrite_block(&mut function.body, subst)
    }

    fn rewrite_block(
        &mut self,
        block: &mut Block,
        subst: &HashMap<String, Type>,
    ) -> Result<(), String> {
        for stmt in &mut block.stmts {
            self.rewrite_stmt(stmt, subst)?;
        }
        Ok(())
    }

    fn rewrite_stmt(
        &mut self,
        stmt: &mut Stmt,
        subst: &HashMap<String, Type>,
    ) -> Result<(), String> {
        match stmt {
            Stmt::Return(value) => {
                if let Some(value) = value {
                    self.rewrite_expr(value, subst)?;
                }
            }
            Stmt::Expr(expr) => self.rewrite_expr(expr, subst)?,
            Stmt::Defer(expr) => self.rewrite_expr(expr, subst)?,
            Stmt::Let { ty, init, .. } => {
                if let Some(ty) = ty {
                    *ty = self.rewrite_type(ty, subst)?;
                }
                if let Some(init) = init {
                    self.rewrite_expr(init, subst)?;
                }
            }
            Stmt::LetTuple { init, .. } => self.rewrite_expr(init, subst)?,
            Stmt::Assign { value, .. } => self.rewrite_expr(value, subst)?,
            Stmt::AssignIndex { lhs, value } => {
                self.rewrite_expr(lhs, subst)?;
                self.rewrite_expr(value, subst)?;
            }
            Stmt::If { cond, then, els } => {
                self.rewrite_expr(cond, subst)?;
                self.rewrite_block(then, subst)?;
                if let Some(els) = els {
                    self.rewrite_block(els, subst)?;
                }
            }
            Stmt::While { cond, body } => {
                self.rewrite_expr(cond, subst)?;
                self.rewrite_block(body, subst)?;
            }
            Stmt::For { iter, body, .. } => {
                self.rewrite_expr(iter, subst)?;
                self.rewrite_block(body, subst)?;
            }
            Stmt::Switch { expr, arms } => {
                self.rewrite_expr(expr, subst)?;
                for arm in arms {
                    self.rewrite_block(&mut arm.body, subst)?;
                }
            }
            Stmt::Break | Stmt::Continue => {}
        }
        Ok(())
    }

    fn rewrite_expr(
        &mut self,
        expr: &mut Expr,
        subst: &HashMap<String, Type>,
    ) -> Result<(), String> {
        match expr {
            Expr::Binary { lhs, rhs, .. } => {
                self.rewrite_expr(lhs, subst)?;
                self.rewrite_expr(rhs, subst)?;
            }
            Expr::Unary { expr, .. } | Expr::AddrOf(expr) | Expr::Deref(expr) => {
                self.rewrite_expr(expr, subst)?;
            }
            Expr::Call {
                callee,
                type_args,
                args,
            } => {
                for arg in args.iter_mut() {
                    self.rewrite_expr(arg, subst)?;
                }
                let concrete_args = type_args
                    .iter()
                    .map(|arg| self.rewrite_type(arg, subst))
                    .collect::<Result<Vec<_>, _>>()?;
                if callee == "sizeof" || callee == "alignof" {
                    if concrete_args.len() != 1 || !args.is_empty() {
                        return Err(format!(
                            "{}[T]() requires exactly one type argument and no value arguments",
                            callee
                        ));
                    }
                    *type_args = concrete_args;
                    return Ok(());
                } else if self.function_templates.contains_key(callee) {
                    if concrete_args.is_empty() {
                        return Err(format!(
                            "generic function '{}' requires explicit type arguments",
                            callee
                        ));
                    }
                    *callee = self.instantiate_function(callee, &concrete_args)?;
                } else if !concrete_args.is_empty() {
                    return Err(format!("function '{}' is not generic", callee));
                }
                type_args.clear();
            }
            Expr::MethodCall {
                receiver,
                method,
                type_args,
                args,
            } => {
                for arg in args.iter_mut() {
                    self.rewrite_expr(arg, subst)?;
                }
                let concrete_args = type_args
                    .iter()
                    .map(|arg| self.rewrite_type(arg, subst))
                    .collect::<Result<Vec<_>, _>>()?;
                if let Expr::Var(type_name) = receiver.as_mut() {
                    if self.enum_templates.contains_key(type_name) {
                        if concrete_args.is_empty() {
                            return Err(format!(
                                "generic enum constructor '{}.{}' requires explicit type arguments",
                                type_name, method
                            ));
                        }
                        *type_name = self.instantiate_type(type_name, &concrete_args)?;
                    } else if self.function_templates.contains_key(method) {
                        if concrete_args.is_empty() {
                            return Err(format!(
                                "generic method '{}' requires explicit type arguments",
                                method
                            ));
                        }
                        *method = self.instantiate_function(method, &concrete_args)?;
                        self.rewrite_expr(receiver, subst)?;
                    } else if !concrete_args.is_empty() {
                        return Err(format!("method or constructor '{}' is not generic", method));
                    } else {
                        self.rewrite_expr(receiver, subst)?;
                    }
                } else {
                    if self.function_templates.contains_key(method) {
                        *method = self.instantiate_function(method, &concrete_args)?;
                    } else if !concrete_args.is_empty() {
                        return Err(format!("method '{}' is not generic", method));
                    }
                    self.rewrite_expr(receiver, subst)?;
                }
                type_args.clear();
            }
            Expr::StructInit {
                name,
                type_args,
                fields,
            } => {
                for (_, value) in fields.iter_mut() {
                    self.rewrite_expr(value, subst)?;
                }
                let concrete_args = type_args
                    .iter()
                    .map(|arg| self.rewrite_type(arg, subst))
                    .collect::<Result<Vec<_>, _>>()?;
                if self.struct_templates.contains_key(name) {
                    if concrete_args.is_empty() {
                        return Err(format!(
                            "generic struct '{}' requires explicit type arguments",
                            name
                        ));
                    }
                    *name = self.instantiate_type(name, &concrete_args)?;
                } else if !concrete_args.is_empty() {
                    return Err(format!("struct '{}' is not generic", name));
                }
                type_args.clear();
            }
            Expr::Field { base, .. } => self.rewrite_expr(base, subst)?,
            Expr::Index { base, index } => {
                self.rewrite_expr(base, subst)?;
                self.rewrite_expr(index, subst)?;
            }
            Expr::Slice { base, lo, hi } => {
                self.rewrite_expr(base, subst)?;
                if let Some(lo) = lo {
                    self.rewrite_expr(lo, subst)?;
                }
                if let Some(hi) = hi {
                    self.rewrite_expr(hi, subst)?;
                }
            }
            Expr::ArrayLit(values) | Expr::Tuple(values) => {
                for value in values {
                    self.rewrite_expr(value, subst)?;
                }
            }
            Expr::Cast { expr, ty } => {
                self.rewrite_expr(expr, subst)?;
                *ty = self.rewrite_type(ty, subst)?;
            }
            Expr::Int(_) | Expr::Float(_) | Expr::Bool(_) | Expr::Str(_) | Expr::Var(_) => {}
        }
        Ok(())
    }
}

fn validate_generic_function(
    function: &Function,
    enums: &HashMap<String, EnumDef>,
    functions: &HashMap<String, Function>,
) -> Result<(), String> {
    let params: HashSet<String> = function.proto.type_params.iter().cloned().collect();
    let mut vars: HashMap<String, Type> = function.proto.params.iter().cloned().collect();
    validate_generic_block(&function.body, &params, enums, functions, &mut vars)
        .map_err(|error| format!("generic function '{}': {}", function.proto.name, error))
}

fn validate_generic_block(
    block: &Block,
    params: &HashSet<String>,
    enums: &HashMap<String, EnumDef>,
    functions: &HashMap<String, Function>,
    vars: &mut HashMap<String, Type>,
) -> Result<(), String> {
    for stmt in &block.stmts {
        match stmt {
            Stmt::Return(value) => {
                if let Some(value) = value {
                    validate_generic_expr(value, params, functions, vars)?;
                }
            }
            Stmt::Expr(expr) => {
                validate_generic_expr(expr, params, functions, vars)?;
            }
            Stmt::Defer(expr) => {
                validate_generic_expr(expr, params, functions, vars)?;
            }
            Stmt::Let { name, ty, init } => {
                if let Some(init) = init {
                    validate_generic_expr(init, params, functions, vars)?;
                }
                let inferred = ty.clone().unwrap_or_else(|| {
                    template_expr_type(init.as_ref().expect("checked by parser"), vars, functions)
                        .unwrap_or_else(|| Type::Named("$dependent".to_string()))
                });
                vars.insert(name.clone(), inferred);
            }
            Stmt::LetTuple { names, init } => {
                validate_generic_expr(init, params, functions, vars)?;
                for name in names {
                    vars.insert(name.clone(), Type::Named("$dependent".to_string()));
                }
            }
            Stmt::Assign { value, .. } => validate_generic_expr(value, params, functions, vars)?,
            Stmt::AssignIndex { lhs, value } => {
                validate_generic_expr(lhs, params, functions, vars)?;
                validate_generic_expr(value, params, functions, vars)?;
            }
            Stmt::If { cond, then, els } => {
                validate_generic_expr(cond, params, functions, vars)?;
                if expr_depends(cond, params, functions, vars) {
                    return Err(
                        "condition depends on an unconstrained type parameter; pass a bool capability"
                            .to_string(),
                    );
                }
                validate_generic_block(then, params, enums, functions, &mut vars.clone())?;
                if let Some(els) = els {
                    validate_generic_block(els, params, enums, functions, &mut vars.clone())?;
                }
            }
            Stmt::While { cond, body } => {
                validate_generic_expr(cond, params, functions, vars)?;
                if expr_depends(cond, params, functions, vars) {
                    return Err(
                        "condition depends on an unconstrained type parameter; pass a bool capability"
                            .to_string(),
                    );
                }
                validate_generic_block(body, params, enums, functions, &mut vars.clone())?;
            }
            Stmt::For { var, iter, body } => {
                validate_generic_expr(iter, params, functions, vars)?;
                let mut inner = vars.clone();
                inner.insert(var.clone(), Type::Named("$dependent".to_string()));
                validate_generic_block(body, params, enums, functions, &mut inner)?;
            }
            Stmt::Switch { expr, arms } => {
                validate_generic_expr(expr, params, functions, vars)?;
                let scrutinee = template_expr_type(expr, vars, functions);
                for arm in arms {
                    let mut inner = vars.clone();
                    if let (
                        Some(Type::Applied(enum_name, type_args)),
                        SwitchPattern::Variant {
                            variant,
                            binding: Some(binding),
                            ..
                        },
                    ) = (&scrutinee, &arm.pattern)
                    {
                        if let Some(def) = enums.get(enum_name) {
                            if let Some(payload) = def
                                .variants
                                .iter()
                                .find(|candidate| candidate.name == *variant)
                                .and_then(|variant| variant.payload.as_ref())
                            {
                                let substitutions: HashMap<String, Type> = def
                                    .type_params
                                    .iter()
                                    .cloned()
                                    .zip(type_args.iter().cloned())
                                    .collect();
                                inner.insert(
                                    binding.clone(),
                                    substitute_plain(payload, &substitutions),
                                );
                            }
                        }
                    }
                    validate_generic_block(&arm.body, params, enums, functions, &mut inner)?;
                }
            }
            Stmt::Break | Stmt::Continue => {}
        }
    }
    Ok(())
}

fn validate_generic_expr(
    expr: &Expr,
    params: &HashSet<String>,
    functions: &HashMap<String, Function>,
    vars: &HashMap<String, Type>,
) -> Result<(), String> {
    match expr {
        Expr::Binary { op, lhs, rhs } => {
            validate_generic_expr(lhs, params, functions, vars)?;
            validate_generic_expr(rhs, params, functions, vars)?;
            if expr_depends(lhs, params, functions, vars)
                || expr_depends(rhs, params, functions, vars)
            {
                return Err(format!(
                    "operator {:?} cannot be used with an unconstrained type parameter; pass a function capability",
                    op
                ));
            }
        }
        Expr::Unary { op, expr } => {
            validate_generic_expr(expr, params, functions, vars)?;
            if expr_depends(expr, params, functions, vars) {
                return Err(format!(
                    "operator {:?} cannot be used with an unconstrained type parameter; pass a function capability",
                    op
                ));
            }
        }
        Expr::Call { callee, args, .. } => {
            for arg in args {
                validate_generic_expr(arg, params, functions, vars)?;
            }
            if callee == "len"
                && args
                    .iter()
                    .any(|arg| expr_depends(arg, params, functions, vars))
            {
                return Err("len() cannot be used with an unconstrained type parameter".to_string());
            }
        }
        Expr::MethodCall { receiver, args, .. } => {
            validate_generic_expr(receiver, params, functions, vars)?;
            for arg in args {
                validate_generic_expr(arg, params, functions, vars)?;
            }
        }
        Expr::StructInit { fields, .. } => {
            for (_, value) in fields {
                validate_generic_expr(value, params, functions, vars)?;
            }
        }
        Expr::Field { base, .. } | Expr::AddrOf(base) | Expr::Deref(base) => {
            validate_generic_expr(base, params, functions, vars)?;
        }
        Expr::Index { base, index } => {
            validate_generic_expr(base, params, functions, vars)?;
            validate_generic_expr(index, params, functions, vars)?;
        }
        Expr::Slice { base, lo, hi } => {
            validate_generic_expr(base, params, functions, vars)?;
            if let Some(lo) = lo {
                validate_generic_expr(lo, params, functions, vars)?;
            }
            if let Some(hi) = hi {
                validate_generic_expr(hi, params, functions, vars)?;
            }
        }
        Expr::ArrayLit(values) | Expr::Tuple(values) => {
            for value in values {
                validate_generic_expr(value, params, functions, vars)?;
            }
        }
        Expr::Cast { expr, ty } => {
            validate_generic_expr(expr, params, functions, vars)?;
            if (expr_depends(expr, params, functions, vars) || type_depends(ty, params))
                && !matches!(ty, Type::Ptr(_))
            {
                return Err("cannot cast an unconstrained type parameter".to_string());
            }
        }
        Expr::Int(_) | Expr::Float(_) | Expr::Bool(_) | Expr::Str(_) | Expr::Var(_) => {}
    }
    Ok(())
}

fn expr_depends(
    expr: &Expr,
    params: &HashSet<String>,
    functions: &HashMap<String, Function>,
    vars: &HashMap<String, Type>,
) -> bool {
    template_expr_type(expr, vars, functions).is_some_and(|ty| type_depends(&ty, params))
}

fn template_expr_type(
    expr: &Expr,
    vars: &HashMap<String, Type>,
    functions: &HashMap<String, Function>,
) -> Option<Type> {
    match expr {
        Expr::Int(_) => Some(Type::Int),
        Expr::Float(_) => Some(Type::Float),
        Expr::Bool(_) => Some(Type::Bool),
        Expr::Str(_) => Some(Type::Str),
        Expr::Var(name) => vars.get(name).cloned(),
        Expr::AddrOf(inner) => Some(Type::Ptr(Box::new(template_expr_type(
            inner, vars, functions,
        )?))),
        Expr::Deref(inner) => match template_expr_type(inner, vars, functions)? {
            Type::Ptr(inner) => Some(*inner),
            _ => None,
        },
        Expr::Call {
            callee, type_args, ..
        } if callee == "sizeof" || callee == "alignof" => Some(Type::U64),
        Expr::Call {
            callee, type_args, ..
        } => match vars.get(callee) {
            Some(Type::Fn(_, ret)) => Some((**ret).clone()),
            _ if !type_args.is_empty() => {
                let function = functions.get(callee)?;
                if function.proto.type_params.len() != type_args.len() {
                    return None;
                }
                let substitutions: HashMap<String, Type> = function
                    .proto
                    .type_params
                    .iter()
                    .cloned()
                    .zip(type_args.iter().cloned())
                    .collect();
                Some(substitute_plain(&function.proto.ret, &substitutions))
            }
            _ => None,
        },
        Expr::MethodCall {
            receiver,
            type_args,
            ..
        } if matches!(receiver.as_ref(), Expr::Var(_)) && !type_args.is_empty() => {
            let Expr::Var(name) = receiver.as_ref() else {
                unreachable!()
            };
            Some(Type::Applied(name.clone(), type_args.clone()))
        }
        Expr::StructInit {
            name, type_args, ..
        } if !type_args.is_empty() => Some(Type::Applied(name.clone(), type_args.clone())),
        Expr::ArrayLit(values) if !values.is_empty() => Some(Type::Array(
            Box::new(template_expr_type(&values[0], vars, functions)?),
            values.len(),
        )),
        Expr::Tuple(values) => Some(Type::Tuple(
            values
                .iter()
                .map(|value| template_expr_type(value, vars, functions))
                .collect::<Option<Vec<_>>>()?,
        )),
        Expr::Cast { ty, .. } => Some(ty.clone()),
        Expr::Unary { expr, .. } => template_expr_type(expr, vars, functions),
        Expr::Binary { lhs, .. } => template_expr_type(lhs, vars, functions),
        Expr::Index { base, .. } => match template_expr_type(base, vars, functions)? {
            Type::Array(inner, _) | Type::Ptr(inner) => Some(*inner),
            Type::Str => Some(Type::U8),
            _ => None,
        },
        Expr::Slice { .. } => Some(Type::Str),
        _ => None,
    }
}

fn type_depends(ty: &Type, params: &HashSet<String>) -> bool {
    match ty {
        Type::Named(name) => params.contains(name) || name == "$dependent",
        Type::Applied(_, args) | Type::Tuple(args) => {
            args.iter().any(|arg| type_depends(arg, params))
        }
        Type::Array(inner, _) | Type::Ptr(inner) => type_depends(inner, params),
        Type::Fn(arguments, ret) => {
            arguments.iter().any(|arg| type_depends(arg, params)) || type_depends(ret, params)
        }
        _ => false,
    }
}

fn substitute_plain(ty: &Type, subst: &HashMap<String, Type>) -> Type {
    match ty {
        Type::Named(name) => subst.get(name).cloned().unwrap_or_else(|| ty.clone()),
        Type::Applied(name, args) => Type::Applied(
            name.clone(),
            args.iter()
                .map(|arg| substitute_plain(arg, subst))
                .collect(),
        ),
        Type::Array(inner, len) => Type::Array(Box::new(substitute_plain(inner, subst)), *len),
        Type::Ptr(inner) => Type::Ptr(Box::new(substitute_plain(inner, subst))),
        Type::Fn(args, ret) => Type::Fn(
            args.iter()
                .map(|arg| substitute_plain(arg, subst))
                .collect(),
            Box::new(substitute_plain(ret, subst)),
        ),
        Type::Tuple(elements) => Type::Tuple(
            elements
                .iter()
                .map(|element| substitute_plain(element, subst))
                .collect(),
        ),
        _ => ty.clone(),
    }
}

fn validate_params(name: &str, params: &[String]) -> Result<(), String> {
    let mut seen = HashSet::new();
    for param in params {
        if !seen.insert(param) {
            return Err(format!(
                "duplicate type parameter '{}' in '{}'",
                param, name
            ));
        }
    }
    Ok(())
}

fn check_arity(name: &str, params: &[String], args: &[Type]) -> Result<(), String> {
    if params.len() != args.len() {
        Err(format!(
            "generic '{}' expects {} type arguments, got {}",
            name,
            params.len(),
            args.len()
        ))
    } else {
        Ok(())
    }
}

fn mangle(name: &str, args: &[Type]) -> String {
    let suffix = args.iter().map(type_key).collect::<Vec<_>>().join("_");
    format!("__ppg_{}_{}_{}", name.len(), name, suffix)
}

pub fn instance_of(concrete: &str, template: &str) -> bool {
    concrete.starts_with(&format!("__ppg_{}_{}_", template.len(), template))
}

fn type_key(ty: &Type) -> String {
    match ty {
        Type::Int => "int".to_string(),
        Type::Float => "float".to_string(),
        Type::Bool => "bool".to_string(),
        Type::Str => "str".to_string(),
        Type::U8 => "u8".to_string(),
        Type::U16 => "u16".to_string(),
        Type::U32 => "u32".to_string(),
        Type::U64 => "u64".to_string(),
        Type::Void => "void".to_string(),
        Type::Named(name) => format!("n{}_{}", name.len(), name),
        Type::Applied(name, args) => format!(
            "n{}_{}_{}",
            name.len(),
            name,
            args.iter().map(type_key).collect::<Vec<_>>().join("_")
        ),
        Type::Array(inner, len) => format!("a{}_{}", len, type_key(inner)),
        Type::Ptr(inner) => format!("p_{}", type_key(inner)),
        Type::Fn(params, ret) => format!(
            "f_{}_r_{}",
            params.iter().map(type_key).collect::<Vec<_>>().join("_"),
            type_key(ret)
        ),
        Type::Tuple(elements) => format!(
            "t_{}",
            elements.iter().map(type_key).collect::<Vec<_>>().join("_")
        ),
    }
}
