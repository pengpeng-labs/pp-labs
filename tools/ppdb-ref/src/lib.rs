use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Value {
    Int(i32),
    Text(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColumnType {
    Int,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
}

#[derive(Clone, Debug)]
struct Row {
    id: u16,
    values: Vec<Value>,
}

#[derive(Clone, Debug)]
struct Index {
    name: String,
    column: usize,
    entries: BTreeMap<i32, Vec<u16>>,
}

#[derive(Clone, Debug)]
struct Table {
    columns: Vec<(String, ColumnType)>,
    rows: Vec<Row>,
    indexes: Vec<Index>,
}

#[derive(Clone, Debug, Default)]
struct State {
    tables: HashMap<String, Table>,
    kv: BTreeMap<String, String>,
    docs: BTreeMap<String, String>,
    next_row_id: u16,
}

#[derive(Default)]
pub struct Database {
    state: State,
    undo: Option<State>,
    pub last_plan: Option<String>,
}

impl Database {
    pub fn new() -> Self {
        Self {
            state: State {
                next_row_id: 1,
                ..State::default()
            },
            undo: None,
            last_plan: None,
        }
    }

    pub fn create_table(
        &mut self,
        name: &str,
        columns: Vec<(&str, ColumnType)>,
    ) -> Result<(), String> {
        if columns.is_empty() || columns.len() > 4 || self.state.tables.contains_key(name) {
            return Err("invalid or duplicate table".into());
        }
        self.state.tables.insert(
            name.into(),
            Table {
                columns: columns.into_iter().map(|(n, t)| (n.into(), t)).collect(),
                rows: Vec::new(),
                indexes: Vec::new(),
            },
        );
        Ok(())
    }

    pub fn insert(&mut self, table: &str, values: Vec<(&str, Value)>) -> Result<u16, String> {
        let row_id = self.state.next_row_id;
        self.state.next_row_id = self
            .state
            .next_row_id
            .checked_add(1)
            .ok_or("row id exhausted")?;
        let target = self.state.tables.get_mut(table).ok_or("no such table")?;
        if values.len() != target.columns.len() {
            return Err("columns/values mismatch".into());
        }
        let mut row = vec![None; target.columns.len()];
        for (name, value) in values {
            let col = target
                .columns
                .iter()
                .position(|(column, _)| column == name)
                .ok_or("no such column")?;
            let type_ok = matches!(
                (&target.columns[col].1, &value),
                (ColumnType::Int, Value::Int(_)) | (ColumnType::Text, Value::Text(_))
            );
            if !type_ok {
                return Err("value type mismatch".into());
            }
            row[col] = Some(value);
        }
        target.rows.push(Row {
            id: row_id,
            values: row
                .into_iter()
                .collect::<Option<Vec<_>>>()
                .ok_or("missing value")?,
        });
        Self::rebuild_indexes(target);
        Ok(row_id)
    }

    pub fn create_index(&mut self, name: &str, table: &str, column: &str) -> Result<(), String> {
        if self
            .state
            .tables
            .values()
            .flat_map(|t| &t.indexes)
            .any(|index| index.name == name)
        {
            return Err("duplicate index".into());
        }
        let target = self.state.tables.get_mut(table).ok_or("no such table")?;
        let col = target
            .columns
            .iter()
            .position(|(name, ty)| name == column && *ty == ColumnType::Int)
            .ok_or("index requires an int column")?;
        if target.indexes.iter().any(|index| index.column == col) {
            return Err("column already indexed".into());
        }
        target.indexes.push(Index {
            name: name.into(),
            column: col,
            entries: BTreeMap::new(),
        });
        Self::rebuild_indexes(target);
        Ok(())
    }

    pub fn select(
        &mut self,
        table: &str,
        projection: &[&str],
        predicate: Option<(&str, CmpOp, Value)>,
    ) -> Result<Vec<Vec<Value>>, String> {
        let target = self.state.tables.get(table).ok_or("no such table")?;
        let projected = projection
            .iter()
            .map(|name| {
                target
                    .columns
                    .iter()
                    .position(|(column, _)| column == name)
                    .ok_or("no such column")
            })
            .collect::<Result<Vec<_>, _>>()?;
        let pred = predicate
            .map(|(name, op, value)| {
                target
                    .columns
                    .iter()
                    .position(|(column, _)| column == name)
                    .map(|column| (column, op, value))
                    .ok_or("no such column")
            })
            .transpose()?;
        self.last_plan = pred.as_ref().and_then(|(column, _, value)| {
            if matches!(value, Value::Int(_)) {
                target
                    .indexes
                    .iter()
                    .find(|index| index.column == *column)
                    .map(|index| index.name.clone())
            } else {
                None
            }
        });
        Ok(target
            .rows
            .iter()
            .filter(|row| {
                pred.as_ref()
                    .is_none_or(|(column, op, value)| compare(&row.values[*column], *op, value))
            })
            .map(|row| {
                projected
                    .iter()
                    .map(|column| row.values[*column].clone())
                    .collect()
            })
            .collect())
    }

    pub fn update(
        &mut self,
        table: &str,
        column: &str,
        value: Value,
        predicate: (&str, CmpOp, Value),
    ) -> Result<usize, String> {
        let target = self.state.tables.get_mut(table).ok_or("no such table")?;
        let set_col = target
            .columns
            .iter()
            .position(|(name, _)| name == column)
            .ok_or("no such column")?;
        let pred_col = target
            .columns
            .iter()
            .position(|(name, _)| name == predicate.0)
            .ok_or("no such column")?;
        let mut count = 0;
        for row in &mut target.rows {
            if compare(&row.values[pred_col], predicate.1, &predicate.2) {
                row.values[set_col] = value.clone();
                count += 1;
            }
        }
        Self::rebuild_indexes(target);
        Ok(count)
    }

    pub fn delete(
        &mut self,
        table: &str,
        predicate: (&str, CmpOp, Value),
    ) -> Result<usize, String> {
        let target = self.state.tables.get_mut(table).ok_or("no such table")?;
        let column = target
            .columns
            .iter()
            .position(|(name, _)| name == predicate.0)
            .ok_or("no such column")?;
        let before = target.rows.len();
        target
            .rows
            .retain(|row| !compare(&row.values[column], predicate.1, &predicate.2));
        let deleted = before - target.rows.len();
        Self::rebuild_indexes(target);
        Ok(deleted)
    }

    pub fn kv_put(&mut self, key: &str, value: &str) {
        self.state.kv.insert(key.into(), value.into());
    }
    pub fn kv_get(&self, key: &str) -> Option<&str> {
        self.state.kv.get(key).map(String::as_str)
    }
    pub fn doc_put(&mut self, name: &str, content: &str) {
        self.state.docs.insert(name.into(), content.into());
    }
    pub fn doc_get(&self, name: &str) -> Option<&str> {
        self.state.docs.get(name).map(String::as_str)
    }

    pub fn begin(&mut self) -> Result<(), String> {
        if self.undo.is_some() {
            return Err("transaction already active".into());
        }
        self.undo = Some(self.state.clone());
        Ok(())
    }
    pub fn commit(&mut self) -> Result<(), String> {
        self.undo
            .take()
            .map(|_| ())
            .ok_or_else(|| "no active transaction".into())
    }
    pub fn rollback(&mut self) -> Result<(), String> {
        self.state = self.undo.take().ok_or("no active transaction")?;
        Ok(())
    }

    fn rebuild_indexes(table: &mut Table) {
        for index in &mut table.indexes {
            index.entries.clear();
            for row in &table.rows {
                if let Value::Int(key) = row.values[index.column] {
                    index.entries.entry(key).or_default().push(row.id);
                }
            }
        }
    }
}

fn compare(left: &Value, op: CmpOp, right: &Value) -> bool {
    let ordering = left.cmp(right);
    match op {
        CmpOp::Eq => ordering.is_eq(),
        CmpOp::Ne => ordering.is_ne(),
        CmpOp::Lt => ordering.is_lt(),
        CmpOp::Gt => ordering.is_gt(),
        CmpOp::Le => ordering.is_le(),
        CmpOp::Ge => ordering.is_ge(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semantic_golden() {
        let mut db = Database::new();
        let mut out = Vec::new();
        db.create_table(
            "people",
            vec![
                ("id", ColumnType::Int),
                ("name", ColumnType::Text),
                ("city", ColumnType::Text),
            ],
        )
        .unwrap();
        db.insert(
            "people",
            vec![
                ("city", Value::Text("Paris".into())),
                ("id", Value::Int(7)),
                ("name", Value::Text("Ada".into())),
            ],
        )
        .unwrap();
        db.insert(
            "people",
            vec![
                ("id", Value::Int(8)),
                ("name", Value::Text("Bob".into())),
                ("city", Value::Text("Rome".into())),
            ],
        )
        .unwrap();
        db.create_index("people_id", "people", "id").unwrap();
        let rows = db
            .select(
                "people",
                &["city", "id"],
                Some(("id", CmpOp::Ge, Value::Int(8))),
            )
            .unwrap();
        out.push(format!("rows={rows:?}"));
        out.push(format!("plan={}", db.last_plan.as_deref().unwrap_or("seq")));
        db.begin().unwrap();
        db.update(
            "people",
            "id",
            Value::Int(9),
            ("name", CmpOp::Eq, Value::Text("Bob".into())),
        )
        .unwrap();
        db.kv_put("tx-key", "temporary");
        db.doc_put("tx-doc", "{\"open\":true}");
        db.rollback().unwrap();
        out.push(format!("rollback-kv={:?}", db.kv_get("tx-key")));
        out.push(format!("rollback-doc={:?}", db.doc_get("tx-doc")));
        db.begin().unwrap();
        db.update(
            "people",
            "id",
            Value::Int(11),
            ("id", CmpOp::Eq, Value::Int(8)),
        )
        .unwrap();
        db.commit().unwrap();
        let committed = db
            .select(
                "people",
                &["id", "name"],
                Some(("id", CmpOp::Eq, Value::Int(11))),
            )
            .unwrap();
        out.push(format!("committed={committed:?}"));
        assert_eq!(
            out.join("\n") + "\n",
            include_str!("../tests/semantic.golden")
        );
    }
}
