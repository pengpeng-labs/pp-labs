//! 词法分析器：把源码字符串切成 token 序列。

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    // 字面量
    Int(i64),
    Float(f64),
    Str(String),
    Ident(String),

    // 关键字
    Fn,
    Extern,
    If,
    Else,
    Return,
    Let,
    While,
    Break,
    Continue,
    Struct,
    Import,
    Static,
    True,
    False,
    For,
    In,
    As,
    Defer,

    // 运算符
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqEq,
    NotEq,
    Lt,
    Gt,
    Le,
    Ge,
    Assign,
    Bang,
    Amp,
    AmpAmp,
    Pipe,
    PipePipe,
    Caret,
    Tilde,
    Shl,
    Shr,

    // 标点
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Semicolon,
    Colon,
    Dot,
    Ellipsis,
    Arrow,

    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub kind: TokenKind,
    pub line: usize,
    pub col: usize,
}

pub struct Lexer {
    src: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
}

impl Lexer {
    pub fn new(src: &str) -> Self {
        Lexer {
            src: src.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
        }
    }

    fn peek(&self) -> Option<char> {
        self.src.get(self.pos).copied()
    }

    fn peek2(&self) -> Option<char> {
        self.src.get(self.pos + 1).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let c = self.src.get(self.pos).copied();
        if let Some(c) = c {
            self.pos += 1;
            if c == '\n' {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        c
    }

    fn skip_whitespace_and_comments(&mut self) -> Result<(), String> {
        loop {
            match (self.peek(), self.peek2()) {
                (Some(c), _) if c.is_whitespace() => {
                    self.advance();
                }
                (Some('/'), Some('/')) => {
                    while let Some(c) = self.peek() {
                        if c == '\n' {
                            break;
                        }
                        self.advance();
                    }
                }
                (Some('/'), Some('*')) => {
                    let (sline, scol) = (self.line, self.col);
                    self.advance();
                    self.advance();
                    let mut closed = false;
                    while let (Some(a), Some(b)) = (self.peek(), self.peek2()) {
                        if a == '*' && b == '/' {
                            self.advance();
                            self.advance();
                            closed = true;
                            break;
                        }
                        self.advance();
                    }
                    if !closed {
                        return Err(format!(
                            "unterminated block comment at line {} col {}",
                            sline, scol
                        ));
                    }
                }
                _ => break,
            }
        }
        Ok(())
    }

    pub fn next_token(&mut self) -> Result<Token, String> {
        self.skip_whitespace_and_comments()?;
        let line = self.line;
        let col = self.col;
        let c = match self.peek() {
            Some(c) => c,
            None => {
                return Ok(Token {
                    kind: TokenKind::Eof,
                    line,
                    col,
                })
            }
        };

        // 标识符 / 关键字
        if c.is_alphabetic() || c == '_' {
            let mut s = String::new();
            while let Some(c) = self.peek() {
                if c.is_alphanumeric() || c == '_' {
                    s.push(c);
                    self.advance();
                } else {
                    break;
                }
            }
            let kind = match s.as_str() {
                "fn" => TokenKind::Fn,
                "extern" => TokenKind::Extern,
                "if" => TokenKind::If,
                "else" => TokenKind::Else,
                "return" => TokenKind::Return,
                "let" => TokenKind::Let,
                "while" => TokenKind::While,
                "break" => TokenKind::Break,
                "continue" => TokenKind::Continue,
                "struct" => TokenKind::Struct,
                "import" => TokenKind::Import,
                "static" => TokenKind::Static,
                "true" => TokenKind::True,
                "false" => TokenKind::False,
                "for" => TokenKind::For,
                "in" => TokenKind::In,
                "as" => TokenKind::As,
                "defer" => TokenKind::Defer,
                _ => TokenKind::Ident(s),
            };
            return Ok(Token { kind, line, col });
        }

        // 数字字面量
        if c.is_ascii_digit() {
            // 十六进制：0x...
            if c == '0' && matches!(self.peek2(), Some('x') | Some('X')) {
                self.advance();
                self.advance();
                let mut s = String::new();
                while let Some(c) = self.peek() {
                    if c.is_ascii_hexdigit() {
                        s.push(c);
                        self.advance();
                    } else {
                        break;
                    }
                }
                let v = i64::from_str_radix(&s, 16)
                    .map_err(|_| format!("invalid hex literal '0x{}' at {}:{}", s, line, col))?;
                return Ok(Token {
                    kind: TokenKind::Int(v),
                    line,
                    col,
                });
            }
            let mut s = String::new();
            while let Some(c) = self.peek() {
                if c.is_ascii_digit() {
                    s.push(c);
                    self.advance();
                } else {
                    break;
                }
            }
            if self.peek() == Some('.') && self.peek2().is_some_and(|d| d.is_ascii_digit()) {
                s.push('.');
                self.advance();
                while let Some(c) = self.peek() {
                    if c.is_ascii_digit() {
                        s.push(c);
                        self.advance();
                    } else {
                        break;
                    }
                }
                let v: f64 = s
                    .parse()
                    .map_err(|_| format!("invalid float '{}' at {}:{}", s, line, col))?;
                return Ok(Token {
                    kind: TokenKind::Float(v),
                    line,
                    col,
                });
            }
            let v: i64 = s
                .parse()
                .map_err(|_| format!("invalid int '{}' at {}:{}", s, line, col))?;
            return Ok(Token {
                kind: TokenKind::Int(v),
                line,
                col,
            });
        }

        // 字符串字面量
        if c == '"' {
            self.advance();
            let mut s = String::new();
            while let Some(c) = self.peek() {
                if c == '"' {
                    self.advance();
                    break;
                }
                if c == '\n' {
                    return Err(format!("unterminated string at {}:{}", line, col));
                }
                if c == '\\' {
                    self.advance();
                    let esc = self.peek().ok_or_else(|| {
                        format!("unterminated escape at {}:{}", line, col)
                    })?;
                    self.advance();
                    match esc {
                        'n' => s.push('\n'),
                        't' => s.push('\t'),
                        'r' => s.push('\r'),
                        '\\' => s.push('\\'),
                        '"' => s.push('"'),
                        '0' => s.push('\0'),
                        other => {
                            return Err(format!(
                                "unknown escape '\\{}' at {}:{}",
                                other, line, col
                            ))
                        }
                    }
                } else {
                    s.push(c);
                    self.advance();
                }
            }
            return Ok(Token {
                kind: TokenKind::Str(s),
                line,
                col,
            });
        }

        // 运算符 / 标点
        let kind = match c {
            '+' => {
                self.advance();
                TokenKind::Plus
            }
            '-' => {
                self.advance();
                if self.peek() == Some('>') {
                    self.advance();
                    TokenKind::Arrow
                } else {
                    TokenKind::Minus
                }
            }
            '*' => {
                self.advance();
                TokenKind::Star
            }
            '/' => {
                self.advance();
                TokenKind::Slash
            }
            '%' => {
                self.advance();
                TokenKind::Percent
            }
            '=' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::EqEq
                } else {
                    TokenKind::Assign
                }
            }
            '!' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::NotEq
                } else {
                    TokenKind::Bang
                }
            }
            '<' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::Le
                } else if self.peek() == Some('<') {
                    self.advance();
                    TokenKind::Shl
                } else {
                    TokenKind::Lt
                }
            }
            '>' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    TokenKind::Ge
                } else if self.peek() == Some('>') {
                    self.advance();
                    TokenKind::Shr
                } else {
                    TokenKind::Gt
                }
            }
            '&' => {
                self.advance();
                if self.peek() == Some('&') {
                    self.advance();
                    TokenKind::AmpAmp
                } else {
                    TokenKind::Amp
                }
            }
            '|' => {
                self.advance();
                if self.peek() == Some('|') {
                    self.advance();
                    TokenKind::PipePipe
                } else {
                    TokenKind::Pipe
                }
            }
            '^' => {
                self.advance();
                TokenKind::Caret
            }
            '~' => {
                self.advance();
                TokenKind::Tilde
            }
            '(' => {
                self.advance();
                TokenKind::LParen
            }
            ')' => {
                self.advance();
                TokenKind::RParen
            }
            '{' => {
                self.advance();
                TokenKind::LBrace
            }
            '}' => {
                self.advance();
                TokenKind::RBrace
            }
            '[' => {
                self.advance();
                TokenKind::LBracket
            }
            ']' => {
                self.advance();
                TokenKind::RBracket
            }
            ',' => {
                self.advance();
                TokenKind::Comma
            }
            ';' => {
                self.advance();
                TokenKind::Semicolon
            }
            ':' => {
                self.advance();
                TokenKind::Colon
            }
            '.' => {
                self.advance();
                if self.peek() == Some('.') && self.peek2() == Some('.') {
                    self.advance();
                    self.advance();
                    TokenKind::Ellipsis
                } else {
                    TokenKind::Dot
                }
            }
            other => {
                return Err(format!("unexpected character '{}' at {}:{}", other, line, col));
            }
        };
        Ok(Token { kind, line, col })
    }
}

/// 一次性把源码切成完整 token 序列（含末尾 Eof）。
pub fn tokenize(src: &str) -> Result<Vec<Token>, String> {
    let mut lexer = Lexer::new(src);
    let mut tokens = Vec::new();
    loop {
        let t = lexer.next_token()?;
        let is_eof = t.kind == TokenKind::Eof;
        tokens.push(t);
        if is_eof {
            break;
        }
    }
    Ok(tokens)
}
