from __future__ import annotations

import ast
from dataclasses import dataclass
from typing import Callable

import numpy as np
import pandas as pd


ALLOWED_BINOPS = (ast.Add, ast.Sub, ast.Mult, ast.Div, ast.Pow)
ALLOWED_UNARY = (ast.UAdd, ast.USub, ast.Not)
ALLOWED_BOOLOPS = (ast.And, ast.Or)
ALLOWED_CMPOPS = (ast.Gt, ast.GtE, ast.Lt, ast.LtE, ast.Eq, ast.NotEq)
ALLOWED_FUNCS = {"abs", "log", "sqrt", "z", "rank", "clip"}


@dataclass
class CompiledExpression:
    raw: str
    tree: ast.AST

    def eval(self, df: pd.DataFrame) -> pd.Series:
        return _eval_node(self.tree, df)


def compile_expression(expr: str) -> CompiledExpression:
    tree = ast.parse(expr, mode="eval")
    _validate(tree)
    return CompiledExpression(raw=expr, tree=tree.body)


def _validate(node: ast.AST) -> None:
    if isinstance(node, ast.Expression):
        _validate(node.body)
        return
    if isinstance(node, ast.Constant):
        return
    if isinstance(node, ast.Name):
        return
    if isinstance(node, ast.BinOp):
        if not isinstance(node.op, ALLOWED_BINOPS):
            raise ValueError("Operator not allowed")
        _validate(node.left)
        _validate(node.right)
        return
    if isinstance(node, ast.UnaryOp):
        if not isinstance(node.op, ALLOWED_UNARY):
            raise ValueError("Unary operator not allowed")
        _validate(node.operand)
        return
    if isinstance(node, ast.BoolOp):
        if not isinstance(node.op, ALLOWED_BOOLOPS):
            raise ValueError("Boolean op not allowed")
        for v in node.values:
            _validate(v)
        return
    if isinstance(node, ast.Compare):
        _validate(node.left)
        for op in node.ops:
            if not isinstance(op, ALLOWED_CMPOPS):
                raise ValueError("Comparison op not allowed")
        for c in node.comparators:
            _validate(c)
        return
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name) or node.func.id not in ALLOWED_FUNCS:
            raise ValueError("Function not allowed")
        for a in node.args:
            _validate(a)
        return
    raise ValueError(f"Unsupported expression node: {type(node).__name__}")


def _as_series(x, df: pd.DataFrame) -> pd.Series:
    if isinstance(x, pd.Series):
        return x
    return pd.Series(x, index=df.index, dtype="float64")


def _zscore_cross(x: pd.Series, df: pd.DataFrame) -> pd.Series:
    grouped = x.groupby(df["date"])
    return grouped.transform(lambda s: (s - s.mean()) / (s.std(ddof=0) + 1e-12))


def _rank_cross(x: pd.Series, df: pd.DataFrame) -> pd.Series:
    return x.groupby(df["date"]).rank(pct=True)


def _eval_node(node: ast.AST, df: pd.DataFrame):
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        if node.id not in df.columns:
            raise ValueError(f"Unknown column: {node.id}")
        return df[node.id]
    if isinstance(node, ast.BinOp):
        l = _as_series(_eval_node(node.left, df), df)
        r = _as_series(_eval_node(node.right, df), df)
        if isinstance(node.op, ast.Add):
            return l + r
        if isinstance(node.op, ast.Sub):
            return l - r
        if isinstance(node.op, ast.Mult):
            return l * r
        if isinstance(node.op, ast.Div):
            return l / (r.replace(0, np.nan))
        if isinstance(node.op, ast.Pow):
            return l**r
    if isinstance(node, ast.UnaryOp):
        x = _as_series(_eval_node(node.operand, df), df)
        if isinstance(node.op, ast.UAdd):
            return x
        if isinstance(node.op, ast.USub):
            return -x
        if isinstance(node.op, ast.Not):
            return ~x.astype(bool)
    if isinstance(node, ast.BoolOp):
        vals = [_as_series(_eval_node(v, df), df).astype(bool) for v in node.values]
        out = vals[0]
        for v in vals[1:]:
            out = out & v if isinstance(node.op, ast.And) else out | v
        return out
    if isinstance(node, ast.Compare):
        left = _as_series(_eval_node(node.left, df), df)
        out = pd.Series(True, index=df.index)
        current = left
        for op, comp in zip(node.ops, node.comparators):
            right = _as_series(_eval_node(comp, df), df)
            if isinstance(op, ast.Gt):
                out &= current > right
            elif isinstance(op, ast.GtE):
                out &= current >= right
            elif isinstance(op, ast.Lt):
                out &= current < right
            elif isinstance(op, ast.LtE):
                out &= current <= right
            elif isinstance(op, ast.Eq):
                out &= current == right
            elif isinstance(op, ast.NotEq):
                out &= current != right
            current = right
        return out
    if isinstance(node, ast.Call):
        fn = node.func.id
        args = [_as_series(_eval_node(a, df), df) for a in node.args]
        if fn == "abs":
            return args[0].abs()
        if fn == "log":
            return np.log(args[0].replace(0, np.nan))
        if fn == "sqrt":
            return np.sqrt(args[0].clip(lower=0))
        if fn == "z":
            return _zscore_cross(args[0], df)
        if fn == "rank":
            return _rank_cross(args[0], df)
        if fn == "clip":
            return args[0].clip(lower=float(args[1].iloc[0]), upper=float(args[2].iloc[0]))
    raise ValueError("Expression evaluation failed")

