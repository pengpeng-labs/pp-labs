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
    Fn(Vec<Type>, Box<Type>),
    Tuple(Vec<Type>),
    Void,
    Named(String),
    Applied(String, Vec<Type>),
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
    In,
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
    Bool(bool),
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
        type_args: Vec<Type>,
        args: Vec<Expr>,
    },
    MethodCall {
        receiver: Box<Expr>,
        method: String,
        type_args: Vec<Type>,
        args: Vec<Expr>,
    },
    StructInit {
        name: String,
        type_args: Vec<Type>,
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
    Slice {
        base: Box<Expr>,
        lo: Option<Box<Expr>>,
        hi: Option<Box<Expr>>,
    },
    ArrayLit(Vec<Expr>),
    Tuple(Vec<Expr>),
    Cast {
        expr: Box<Expr>,
        ty: Type,
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
    LetTuple {
        names: Vec<String>,
        init: Expr,
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
    For {
        var: String,
        iter: Expr,
        body: Block,
    },
    Switch {
        expr: Expr,
        arms: Vec<SwitchArm>,
    },
    Defer(Box<Expr>),
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
    pub type_params: Vec<String>,
    pub params: Vec<(String, Type)>,
    pub ret: Type,
    pub is_var_arg: bool,
}

#[derive(Debug, Clone)]
pub struct Function {
    pub proto: Prototype,
    pub body: Block,
}

#[derive(Debug, Clone)]
pub struct StructDef {
    pub name: String,
    pub type_params: Vec<String>,
    pub fields: Vec<(String, Type)>,
}

#[derive(Debug, Clone)]
pub struct EnumVariant {
    pub name: String,
    pub payload: Option<Type>,
}

#[derive(Debug, Clone)]
pub struct EnumDef {
    pub name: String,
    pub type_params: Vec<String>,
    pub variants: Vec<EnumVariant>,
}

#[derive(Debug, Clone)]
pub enum SwitchPattern {
    Variant {
        enum_name: String,
        variant: String,
        binding: Option<String>,
    },
    Wildcard,
}

#[derive(Debug, Clone)]
pub struct SwitchArm {
    pub pattern: SwitchPattern,
    pub body: Block,
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
    Enum(EnumDef),
    Import(String),
    Static(Static),
}
