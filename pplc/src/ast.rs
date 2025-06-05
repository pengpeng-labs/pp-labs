//! 抽象语法树（AST）定义。

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Type {
    Int,
    Float,
    Bool,
    Str,
    U8,
    U16,
    U32,
    U64,
    Array(Box<Type>, usize),
    Ptr(Box<Type>),
    Void,
    Named(String),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Not,
    BitNot,
}

#[derive(Debug, Clone)]
pub enum Expr {
    Int(i64),
    Float(f64),
    Str(String),
    Var(String),
    Binary {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
    Unary {
        op: UnOp,
        expr: Box<Expr>,
    },
    Call {
        callee: String,
        args: Vec<Expr>,
    },
    StructInit {
        name: String,
        fields: Vec<(String, Expr)>,
    },
    Field {
        base: Box<Expr>,
        field: String,
    },
    Index {
        base: Box<Expr>,
        index: Box<Expr>,
    },
    AddrOf(Box<Expr>),
    Deref(Box<Expr>),
}

#[derive(Debug, Clone)]
pub enum Stmt {
    Return(Option<Expr>),
    Expr(Expr),
    Let {
        name: String,
        ty: Option<Type>,
        init: Option<Expr>,
    },
    Assign {
        name: String,
        value: Expr,
    },
    AssignIndex {
        lhs: Expr,
        value: Expr,
    },
    If {
        cond: Expr,
        then: Block,
        els: Option<Block>,
    },
    While {
        cond: Expr,
        body: Block,
    },
    Break,
    Continue,
}

#[derive(Debug, Clone)]
pub struct Block {
    pub stmts: Vec<Stmt>,
}

#[derive(Debug, Clone)]
pub struct Prototype {
    pub name: String,
    pub params: Vec<(String, Type)>,
    pub ret: Type,
}

#[derive(Debug, Clone)]
pub struct Function {
    pub proto: Prototype,
    pub body: Block,
}

#[derive(Debug, Clone)]
pub struct StructDef {
    pub name: String,
    pub fields: Vec<(String, Type)>,
}

#[derive(Debug, Clone)]
pub struct Static {
    pub name: String,
    pub ty: Type,
    pub init: Option<Expr>,
}

#[derive(Debug, Clone)]
pub enum Item {
    Extern(Prototype),
    Function(Function),
    Struct(StructDef),
    Import(String),
    Static(Static),
}
