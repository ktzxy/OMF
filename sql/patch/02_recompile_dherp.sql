-- 重编译 DHERP 模式下的所有 INVALID 对象 (修复 impdp 导入产生的 ORA-39082 编译警告)
-- 框架会在开头自动注入: ALTER SESSION SET CONTAINER = ARTERYPDB;
-- 用 DBMS_UTILITY.COMPILE_SCHEMA 按依赖循环重编译 (compile_all=>FALSE 仅重编译当前 INVALID 对象)。
-- 注: 不用 UTL_RECOMP.RECOMPILE_SCHEMA, 因其在本环境 PDB 内解析不到该过程 (PLS-00302)。
BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'DHERP', compile_all => FALSE);
END;
/
