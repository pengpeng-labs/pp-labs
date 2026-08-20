//! 递归下降解析器：token 序列 → AST。

use crate::ast::*;
use crate::lexer::{Token, TokenKind};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    no_struct_init: bool,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0, no_struct_init: false }
    }

    fn peek(&self) -> &TokenKind {
        &self.tokens[self.pos].kind
    }

    fn advance(&mut self) -> Token {
        let t = self.tokens[self.pos].clone();
        if self.pos + 1 < self.tokens.len() {
            self.pos += 1;
        }
        t
    }

    fn eat(&mut self, kind: &TokenKind) -> bool {
        if self.peek() == kind {
            self.advance();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, kind: &TokenKind, what: &str) -> Result<Token, String> {
        if self.peek() == kind {
            Ok(self.advance())
        } else {
            let t = &self.tokens[self.pos];
            Err(format!(
                "expected {} at {}:{}, got {:?}",
                what, t.line, t.col, t.kind
            ))
        }
    }

    fn expect_ident(&mut self, what: &str) -> Result<String, String> {
        let t = self.advance();
        match t.kind {
            TokenKind::Ident(s) => Ok(s),
            _ => Err(format!(
                "expected {} at {}:{}, got {:?}",
                what, t.line, t.col, t.kind
            )),
        }
    }

    // ---------------------------------------------------------------
    // 顶层
    // ---------------------------------------------------------------

    pub fn parse_program(&mut self) -> Result<Vec<Item>, String> {
        let mut items = Vec::new();
        while *self.peek() != TokenKind::Eof {
            if self.eat(&TokenKind::Extern) {
                let proto = self.parse_prototype()?;
                self.expect(&TokenKind::Semicolon, "';' after extern")?;
                items.push(Item::Extern(proto));
            } else if self.eat(&TokenKind::Struct) {
                items.push(Item::Struct(self.parse_struct_def()?));
            } else if self.eat(&TokenKind::Enum) {
                items.push(Item::Enum(self.parse_enum_def()?));
            } else if self.eat(&TokenKind::Import) {
                let t = self.advance();
                let path = match t.kind {
                    TokenKind::Str(s) => s,
                    _ => return Err(format!("expected string after import at {}:{}", t.line, t.col)),
                };
                self.expect(&TokenKind::Semicolon, "';' after import")?;
                items.push(Item::Import(path));
            } else if self.eat(&TokenKind::Static) {
                let name = self.expect_ident("static name")?;
                self.expect(&TokenKind::Colon, "':'")?;
                let ty = self.parse_type()?;
                let init = if self.eat(&TokenKind::Assign) {
                    let e = self.parse_expr()?;
                    Some(e)
                } else {
                    None
                };
                self.expect(&TokenKind::Semicolon, "';' after static")?;
                items.push(Item::Static(Static { name, ty, init }));
            } else {
                let proto = self.parse_prototype()?;
                let body = self.parse_block()?;
                items.push(Item::Function(Function { proto, body }));
            }
        }
        Ok(items)
    }

    fn parse_struct_def(&mut self) -> Result<StructDef, String> {
        let name = self.expect_ident("struct name")?;
        let type_params = self.parse_type_params()?;
        self.expect(&TokenKind::LBrace, "'{'")?;
        let mut fields = Vec::new();
        while !self.eat(&TokenKind::RBrace) {
            let fname = self.expect_ident("field name")?;
            self.expect(&TokenKind::Colon, "':'")?;
            let ftype = self.parse_type()?;
            fields.push((fname, ftype));
            if self.eat(&TokenKind::Comma) {
                continue;
            }
            self.expect(&TokenKind::RBrace, "'}'")?;
            break;
        }
        Ok(StructDef {
            name,
            type_params,
            fields,
        })
    }

    fn parse_enum_def(&mut self) -> Result<EnumDef, String> {
        let name = self.expect_ident("enum name")?;
        let type_params = self.parse_type_params()?;
        self.expect(&TokenKind::LBrace, "'{'")?;
        let mut variants = Vec::new();
        while !self.eat(&TokenKind::RBrace) {
            let variant_name = self.expect_ident("enum variant name")?;
            let payload = if self.eat(&TokenKind::LParen) {
                let ty = self.parse_type()?;
                self.expect(&TokenKind::RParen, "')' after enum payload type")?;
                Some(ty)
            } else {
                None
            };
            variants.push(EnumVariant {
                name: variant_name,
                payload,
            });
            if self.eat(&TokenKind::Comma) {
                continue;
            }
            self.expect(&TokenKind::RBrace, "'}' after enum variants")?;
            break;
        }
        Ok(EnumDef {
            name,
            type_params,
            variants,
        })
    }

    fn parse_prototype(&mut self) -> Result<Prototype, String> {
        self.expect(&TokenKind::Fn, "'fn'")?;
        let name = self.expect_ident("function name")?;
        let type_params = self.parse_type_params()?;
        self.expect(&TokenKind::LParen, "'('")?;
        let mut params = Vec::new();
        let mut is_var_arg = false;
        if !self.eat(&TokenKind::RParen) {
            loop {
                if self.eat(&TokenKind::Ellipsis) {
                    is_var_arg = true;
                    self.expect(&TokenKind::RParen, "')' after '...'")?;
                    break;
                }
                let pname = self.expect_ident("parameter name")?;
                self.expect(&TokenKind::Colon, "':'")?;
                let ptype = self.parse_type()?;
                params.push((pname, ptype));
                if self.eat(&TokenKind::Comma) {
                    continue;
                }
                self.expect(&TokenKind::RParen, "')'")?;
                break;
            }
        }
        let ret = if self.eat(&TokenKind::Arrow) {
            self.parse_type()?
        } else {
            Type::Void
        };
        Ok(Prototype {
            name,
            type_params,
            params,
            ret,
            is_var_arg,
        })
    }

    fn parse_type_params(&mut self) -> Result<Vec<String>, String> {
        if !self.eat(&TokenKind::LBracket) {
            return Ok(Vec::new());
        }
        let mut params = Vec::new();
        loop {
            params.push(self.expect_ident("type parameter")?);
            if self.eat(&TokenKind::Comma) {
                continue;
            }
            self.expect(&TokenKind::RBracket, "']' after type parameters")?;
            break;
        }
        Ok(params)
    }

    fn parse_type_args(&mut self) -> Result<Vec<Type>, String> {
        self.expect(&TokenKind::LBracket, "'[' before type arguments")?;
        let mut args = Vec::new();
        loop {
            args.push(self.parse_type()?);
            if self.eat(&TokenKind::Comma) {
                continue;
            }
            self.expect(&TokenKind::RBracket, "']' after type arguments")?;
            break;
        }
        Ok(args)
    }

    fn parse_type(&mut self) -> Result<Type, String> {
        if self.eat(&TokenKind::LParen) {
            let mut elements = vec![self.parse_type()?];
            self.expect(&TokenKind::Comma, "',' in tuple type")?;
            loop {
                elements.push(self.parse_type()?);
                if self.eat(&TokenKind::Comma) {
                    continue;
                }
                self.expect(&TokenKind::RParen, "')' after tuple type")?;
                break;
            }
            return Ok(Type::Tuple(elements));
        }
        if self.eat(&TokenKind::Star) {
            let inner = self.parse_type()?;
            return Ok(Type::Ptr(Box::new(inner)));
        }
        if self.eat(&TokenKind::Fn) {
            // 函数指针类型：fn(param, ...) -> ret
            self.expect(&TokenKind::LParen, "'(' after fn")?;
            let mut params = Vec::new();
            if !self.eat(&TokenKind::RParen) {
                loop {
                    params.push(self.parse_type()?);
                    if self.eat(&TokenKind::Comma) {
                        continue;
                    }
                    self.expect(&TokenKind::RParen, "')'")?;
                    break;
                }
            }
            let ret = if self.eat(&TokenKind::Arrow) {
                self.parse_type()?
            } else {
                Type::Void
            };
            return Ok(Type::Fn(params, Box::new(ret)));
        }
        if self.eat(&TokenKind::LBracket) {
            // 数组类型：[N]T（长度前置，Go/Zig 式）。
            if let TokenKind::Int(v) = self.peek() {
                let len = *v;
                self.advance();
                self.expect(&TokenKind::RBracket, "']'")?;
                let elem = self.parse_type()?;
                return Ok(Type::Array(Box::new(elem), len as usize));
            }
            let t = &self.tokens[self.pos];
            return Err(format!(
                "legacy array type syntax is not supported at {}:{}; use [N]T",
                t.line, t.col
            ));
        }
        let t = self.advance();
        match t.kind {
            TokenKind::Ident(s) => match s.as_str() {
                "int" => Ok(Type::Int),
                "float" => Ok(Type::Float),
                "bool" => Ok(Type::Bool),
                "str" => Ok(Type::Str),
                "u8" => Ok(Type::U8),
                "u16" => Ok(Type::U16),
                "u32" => Ok(Type::U32),
                "u64" => Ok(Type::U64),
                "void" => Ok(Type::Void),
                _ => {
                    if matches!(self.peek(), TokenKind::LBracket) {
                        Ok(Type::Applied(s, self.parse_type_args()?))
                    } else {
                        Ok(Type::Named(s))
                    }
                }
            },
            _ => Err(format!(
                "expected type at {}:{}, got {:?}",
                t.line, t.col, t.kind
            )),
        }
    }

    fn parse_block(&mut self) -> Result<Block, String> {
        self.expect(&TokenKind::LBrace, "'{'")?;
        let mut stmts = Vec::new();
        while *self.peek() != TokenKind::RBrace && *self.peek() != TokenKind::Eof {
            stmts.push(self.parse_stmt()?);
        }
        self.expect(&TokenKind::RBrace, "'}'")?;
        Ok(Block { stmts })
    }

    // ---------------------------------------------------------------
    // 语句
    // ---------------------------------------------------------------

    fn parse_stmt(&mut self) -> Result<Stmt, String> {
        match self.peek() {
            TokenKind::Return => {
                self.advance();
                let expr = if self.eat(&TokenKind::Semicolon) {
                    None
                } else {
                    let e = self.parse_expr()?;
                    self.expect(&TokenKind::Semicolon, "';' after return")?;
                    Some(e)
                };
                Ok(Stmt::Return(expr))
            }
            TokenKind::Let => {
                self.advance();
                if self.eat(&TokenKind::LParen) {
                    let mut names = Vec::new();
                    loop {
                        names.push(self.expect_ident("tuple binding name")?);
                        if self.eat(&TokenKind::Comma) {
                            continue;
                        }
                        self.expect(&TokenKind::RParen, "')' after tuple binding")?;
                        break;
                    }
                    if names.len() < 2 {
                        return Err("tuple binding requires at least two names".to_string());
                    }
                    self.expect(&TokenKind::Assign, "'=' after tuple binding")?;
                    let init = self.parse_expr()?;
                    self.expect(&TokenKind::Semicolon, "';' after tuple binding")?;
                    return Ok(Stmt::LetTuple { names, init });
                }
                let name = self.expect_ident("variable name")?;
                let ty = if self.eat(&TokenKind::Colon) {
                    Some(self.parse_type()?)
                } else {
                    None
                };
                let init = if self.eat(&TokenKind::Assign) {
                    Some(self.parse_expr()?)
                } else {
                    None
                };
                self.expect(&TokenKind::Semicolon, "';' after let")?;
                Ok(Stmt::Let { name, ty, init })
            }
            TokenKind::While => {
                self.advance();
                self.expect(&TokenKind::LParen, "'(' after while")?;
                let cond = self.parse_expr()?;
                self.expect(&TokenKind::RParen, "')' after condition")?;
                let body = self.parse_block()?;
                Ok(Stmt::While { cond, body })
            }
            TokenKind::For => {
                self.advance();
                let var = self.expect_ident("loop variable")?;
                self.expect(&TokenKind::In, "'in' after loop variable")?;
                self.no_struct_init = true;
                let iter = self.parse_expr()?;
                self.no_struct_init = false;
                let body = self.parse_block()?;
                Ok(Stmt::For { var, iter, body })
            }
            TokenKind::Switch => self.parse_switch(),
            TokenKind::Break => {
                self.advance();
                self.expect(&TokenKind::Semicolon, "';' after break")?;
                Ok(Stmt::Break)
            }
            TokenKind::Defer => {
                self.advance();
                let e = self.parse_expr()?;
                self.expect(&TokenKind::Semicolon, "';' after defer")?;
                Ok(Stmt::Defer(Box::new(e)))
            }
            TokenKind::Continue => {
                self.advance();
                self.expect(&TokenKind::Semicolon, "';' after continue")?;
                Ok(Stmt::Continue)
            }
            TokenKind::If => {
                self.advance();
                self.expect(&TokenKind::LParen, "'(' after if")?;
                let cond = self.parse_expr()?;
                self.expect(&TokenKind::RParen, "')' after condition")?;
                let then = self.parse_block()?;
                let els = if self.eat(&TokenKind::Else) {
                    if matches!(self.peek(), TokenKind::If) {
                        // else if：把嵌套的 if 语句包成块
                        let nested = self.parse_stmt()?;
                        Some(Block {
                            stmts: vec![nested],
                        })
                    } else {
                        Some(self.parse_block()?)
                    }
                } else {
                    None
                };
                Ok(Stmt::If { cond, then, els })
            }
            TokenKind::Star => {
                let lhs = self.parse_unary()?;
                self.expect(&TokenKind::Assign, "'=' in deref assignment")?;
                let value = self.parse_expr()?;
                self.expect(&TokenKind::Semicolon, "';' after assignment")?;
                Ok(Stmt::AssignIndex { lhs, value })
            }
            TokenKind::Ident(_) => {
                // 赋值语句：ident = expr ;
                if matches!(self.peek_next(), TokenKind::Assign) {
                    let name = self.expect_ident("variable name")?;
                    self.advance(); // '='
                    let value = self.parse_expr()?;
                    self.expect(&TokenKind::Semicolon, "';' after assignment")?;
                    return Ok(Stmt::Assign { name, value });
                }
                // 复合左值赋值：下标 / 字段。
                if matches!(self.peek_next(), TokenKind::LBracket | TokenKind::Dot) {
                    let lhs = self.parse_postfix()?;
                    if !self.eat(&TokenKind::Assign) {
                        self.expect(&TokenKind::Semicolon, "';' after expression")?;
                        return Ok(Stmt::Expr(lhs));
                    }
                    let value = self.parse_expr()?;
                    self.expect(&TokenKind::Semicolon, "';' after assignment")?;
                    return Ok(Stmt::AssignIndex { lhs, value });
                }
                let e = self.parse_expr()?;
                self.expect(&TokenKind::Semicolon, "';' after expression")?;
                Ok(Stmt::Expr(e))
            }
            _ => {
                let e = self.parse_expr()?;
                self.expect(&TokenKind::Semicolon, "';' after expression")?;
                Ok(Stmt::Expr(e))
            }
        }
    }

    fn parse_switch(&mut self) -> Result<Stmt, String> {
        self.expect(&TokenKind::Switch, "'switch'")?;
        self.no_struct_init = true;
        let expr = self.parse_expr()?;
        self.no_struct_init = false;
        self.expect(&TokenKind::LBrace, "'{' after switch value")?;
        let mut arms = Vec::new();
        while !self.eat(&TokenKind::RBrace) {
            let first = self.expect_ident("switch pattern")?;
            let pattern = if first == "_" {
                SwitchPattern::Wildcard
            } else {
                self.expect(&TokenKind::Dot, "'.' in enum pattern")?;
                let variant = self.expect_ident("enum variant")?;
                let binding = if self.eat(&TokenKind::LParen) {
                    let name = self.expect_ident("payload binding")?;
                    self.expect(&TokenKind::RParen, "')' after payload binding")?;
                    Some(name)
                } else {
                    None
                };
                SwitchPattern::Variant {
                    enum_name: first,
                    variant,
                    binding,
                }
            };
            let body = self.parse_block()?;
            arms.push(SwitchArm { pattern, body });
        }
        Ok(Stmt::Switch { expr, arms })
    }

    fn peek_next(&self) -> &TokenKind {
        let i = (self.pos + 1).min(self.tokens.len() - 1);
        &self.tokens[i].kind
    }

    // ---------------------------------------------------------------
    // 表达式（优先级爬升）
    // ---------------------------------------------------------------

    fn parse_expr(&mut self) -> Result<Expr, String> {
        self.parse_binary(0)
    }

    fn binop_precedence(kind: &TokenKind) -> Option<u8> {
        let p = match kind {
            TokenKind::PipePipe => 1,
            TokenKind::AmpAmp => 2,
            TokenKind::Pipe => 3,
            TokenKind::Caret => 4,
            TokenKind::Amp => 5,
            TokenKind::EqEq | TokenKind::NotEq | TokenKind::Lt | TokenKind::Gt | TokenKind::Le
            | TokenKind::Ge | TokenKind::In => 6,
            TokenKind::Shl | TokenKind::Shr => 7,
            TokenKind::Plus | TokenKind::Minus => 8,
            TokenKind::Star | TokenKind::Slash | TokenKind::Percent => 9,
            _ => return None,
        };
        Some(p)
    }

    fn binop_from(kind: &TokenKind) -> BinOp {
        match kind {
            TokenKind::Plus => BinOp::Add,
            TokenKind::Minus => BinOp::Sub,
            TokenKind::Star => BinOp::Mul,
            TokenKind::Slash => BinOp::Div,
            TokenKind::Percent => BinOp::Mod,
            TokenKind::EqEq => BinOp::Eq,
            TokenKind::NotEq => BinOp::Ne,
            TokenKind::Lt => BinOp::Lt,
            TokenKind::Gt => BinOp::Gt,
            TokenKind::Le => BinOp::Le,
            TokenKind::Ge => BinOp::Ge,
            TokenKind::AmpAmp => BinOp::And,
            TokenKind::PipePipe => BinOp::Or,
            TokenKind::Amp => BinOp::BitAnd,
            TokenKind::Pipe => BinOp::BitOr,
            TokenKind::Caret => BinOp::BitXor,
            TokenKind::Shl => BinOp::Shl,
            TokenKind::Shr => BinOp::Shr,
            TokenKind::In => BinOp::In,
            _ => unreachable!(),
        }
    }

    fn parse_binary(&mut self, min_prec: u8) -> Result<Expr, String> {
        let mut lhs = self.parse_unary()?;
        loop {
            let prec = match Self::binop_precedence(self.peek()) {
                Some(p) if p >= min_prec => p,
                _ => break,
            };
            let op = Self::binop_from(self.peek());
            self.advance();
            let rhs = self.parse_binary(prec + 1)?;
            lhs = Expr::Binary {
                op,
                lhs: Box::new(lhs),
                rhs: Box::new(rhs),
            };
        }
        Ok(lhs)
    }

    fn parse_unary(&mut self) -> Result<Expr, String> {
        match self.peek() {
            TokenKind::Minus => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary {
                    op: UnOp::Neg,
                    expr: Box::new(e),
                })
            }
            TokenKind::Bang => {
                self.advance();
                let e = self.parse_unary()?;
                Ok(Expr::Unary {
                    op: UnOp::Not,
                    expr: Box::new(e),
                })
            }
            TokenKind::Amp => {
                self.advance();
                let inner = self.parse_unary()?;
                Ok(Expr::AddrOf(Box::new(inner)))
            }
            TokenKind::Star => {
                self.advance();
                let inner = self.parse_unary()?;
                Ok(Expr::Deref(Box::new(inner)))
            }
            TokenKind::Tilde => {
                self.advance();
                let inner = self.parse_unary()?;
                Ok(Expr::Unary {
                    op: UnOp::BitNot,
                    expr: Box::new(inner),
                })
            }
            _ => self.parse_postfix(),
        }
    }

    fn parse_postfix(&mut self) -> Result<Expr, String> {
        let mut expr = self.parse_primary()?;
        loop {
            if self.eat(&TokenKind::Dot) {
                let field = self.expect_ident("field name")?;
                let saved = self.pos;
                let type_args = if matches!(self.peek(), TokenKind::LBracket) {
                    match self.parse_type_args() {
                        Ok(args) if matches!(self.peek(), TokenKind::LParen) => args,
                        _ => {
                            self.pos = saved;
                            Vec::new()
                        }
                    }
                } else {
                    Vec::new()
                };
                if self.eat(&TokenKind::LParen) {
                    // 保留接收者信息，语义阶段决定按值传递还是自动取址。
                    let mut args = Vec::new();
                    if !self.eat(&TokenKind::RParen) {
                        loop {
                            args.push(self.parse_expr()?);
                            if self.eat(&TokenKind::Comma) {
                                continue;
                            }
                            self.expect(&TokenKind::RParen, "')'")?;
                            break;
                        }
                    }
                    expr = Expr::MethodCall {
                        receiver: Box::new(expr),
                        method: field,
                        type_args,
                        args,
                    };
                } else {
                    expr = Expr::Field {
                        base: Box::new(expr),
                        field,
                    };
                }
            } else if self.eat(&TokenKind::LBracket) {
                if self.eat(&TokenKind::Colon) {
                    // 切片 s[:b] 或 s[:]
                    if self.eat(&TokenKind::RBracket) {
                        expr = Expr::Slice {
                            base: Box::new(expr),
                            lo: None,
                            hi: None,
                        };
                    } else {
                        let hi = self.parse_expr()?;
                        self.expect(&TokenKind::RBracket, "']'")?;
                        expr = Expr::Slice {
                            base: Box::new(expr),
                            lo: None,
                            hi: Some(Box::new(hi)),
                        };
                    }
                } else {
                    let first = self.parse_expr()?;
                    if self.eat(&TokenKind::Colon) {
                        // 切片 s[a:b] 或 s[a:]
                        if self.eat(&TokenKind::RBracket) {
                            expr = Expr::Slice {
                                base: Box::new(expr),
                                lo: Some(Box::new(first)),
                                hi: None,
                            };
                        } else {
                            let hi = self.parse_expr()?;
                            self.expect(&TokenKind::RBracket, "']'")?;
                            expr = Expr::Slice {
                                base: Box::new(expr),
                                lo: Some(Box::new(first)),
                                hi: Some(Box::new(hi)),
                            };
                        }
                    } else {
                        self.expect(&TokenKind::RBracket, "']'")?;
                        expr = Expr::Index {
                            base: Box::new(expr),
                            index: Box::new(first),
                        };
                    }
                }
            } else if self.eat(&TokenKind::As) {
                let ty = self.parse_type()?;
                expr = Expr::Cast {
                    expr: Box::new(expr),
                    ty,
                };
            } else {
                break;
            }
        }
        Ok(expr)
    }

    fn parse_primary(&mut self) -> Result<Expr, String> {
        match self.peek().clone() {
            TokenKind::Int(v) => {
                self.advance();
                Ok(Expr::Int(v))
            }
            TokenKind::Float(v) => {
                self.advance();
                Ok(Expr::Float(v))
            }
            TokenKind::True => {
                self.advance();
                Ok(Expr::Bool(true))
            }
            TokenKind::False => {
                self.advance();
                Ok(Expr::Bool(false))
            }
            TokenKind::Str(s) => {
                self.advance();
                Ok(Expr::Str(s))
            }
            TokenKind::Ident(name) => {
                self.advance();
                let saved = self.pos;
                let type_args = if matches!(self.peek(), TokenKind::LBracket) {
                    match self.parse_type_args() {
                        Ok(args)
                            if matches!(self.peek(), TokenKind::LParen | TokenKind::LBrace) =>
                        {
                            args
                        }
                        _ => {
                            self.pos = saved;
                            Vec::new()
                        }
                    }
                } else {
                    Vec::new()
                };
                if self.eat(&TokenKind::LParen) {
                    let mut args = Vec::new();
                    if !self.eat(&TokenKind::RParen) {
                        loop {
                            args.push(self.parse_expr()?);
                            if self.eat(&TokenKind::Comma) {
                                continue;
                            }
                            self.expect(&TokenKind::RParen, "')'")?;
                            break;
                        }
                    }
                    Ok(Expr::Call {
                        callee: name,
                        type_args,
                        args,
                    })
                } else if !self.no_struct_init && self.eat(&TokenKind::LBrace) {
                    let mut fields = Vec::new();
                    if !self.eat(&TokenKind::RBrace) {
                        loop {
                            let fname = self.expect_ident("field name")?;
                            self.expect(&TokenKind::Colon, "':'")?;
                            let fexpr = self.parse_expr()?;
                            fields.push((fname, fexpr));
                            if self.eat(&TokenKind::Comma) {
                                continue;
                            }
                            self.expect(&TokenKind::RBrace, "'}'")?;
                            break;
                        }
                    }
                    Ok(Expr::StructInit {
                        name,
                        type_args,
                        fields,
                    })
                } else {
                    Ok(Expr::Var(name))
                }
            }
            TokenKind::LParen => {
                self.advance();
                let first = self.parse_expr()?;
                if self.eat(&TokenKind::Comma) {
                    let mut values = vec![first];
                    loop {
                        values.push(self.parse_expr()?);
                        if self.eat(&TokenKind::Comma) {
                            continue;
                        }
                        self.expect(&TokenKind::RParen, "')' after tuple")?;
                        break;
                    }
                    Ok(Expr::Tuple(values))
                } else {
                    self.expect(&TokenKind::RParen, "')'")?;
                    Ok(first)
                }
            }
            TokenKind::LBracket => {
                // 数组字面量：[elem, elem, ...]
                self.advance();
                let mut elems = Vec::new();
                if !self.eat(&TokenKind::RBracket) {
                    loop {
                        elems.push(self.parse_expr()?);
                        if self.eat(&TokenKind::Comma) {
                            continue;
                        }
                        self.expect(&TokenKind::RBracket, "']'")?;
                        break;
                    }
                }
                Ok(Expr::ArrayLit(elems))
            }
            other => {
                let t = &self.tokens[self.pos];
                Err(format!(
                    "unexpected token {:?} at {}:{}",
                    other, t.line, t.col
                ))
            }
        }
    }
}
