# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "5"
# ///
"""
Pytest configuration for local and CI runs.

Files in tests/ that are Databricks notebooks (first line
"# Databricks notebook source") need spark and dbutils, so they only run
in Databricks. Pytest skips them here.
"""
from pathlib import Path

DATABRICKS_HEADER = "# Databricks notebook source"


def pytest_ignore_collect(collection_path, config):
    path = Path(collection_path)
    if path.suffix != ".py" or not path.is_file():
        return None
    with path.open(encoding="utf-8") as f:
        if f.readline().strip() == DATABRICKS_HEADER:
            return True
    return None