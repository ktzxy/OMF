-- 重编译 DHERP 模式下的所有 INVALID 对象 (修复 impdp 导入产生的 ORA-39082 编译警告)
-- 框架会在开头自动注入: ALTER SESSION SET CONTAINER = ARTERYPDB;
-- UTL_RECOMP 按依赖顺序重编译整个 schema, 比逐条 ALTER ... COMPILE 更稳。
BEGIN
    UTL_RECOMP.RECOMPILE_SCHEMA('DHERP');
END;
/
