--===============================================================================
-- OMF 初始化脚本: 创建表空间和应用用户 (幂等版)
-- 基于原始 createtabelspace.sql 标准化
--
-- 幂等说明: Oracle 的 CREATE TABLESPACE / CREATE USER 没有 IF NOT EXISTS 语法,
--   因此用 PL/SQL + EXECUTE IMMEDIATE, 通过 EXCEPTION 精确吞掉:
--     ORA-01543 (表空间已存在)
--     ORA-01920 (用户已存在)
--   其余任何真实错误仍会抛出, 被 sql_execute_one 的三重检测捕获并报错。
--   GRANT 重复执行不报错; CREATE OR REPLACE DIRECTORY 本身幂等。
--===============================================================================

-- 切换到 PDB (PDB 必须 OPEN, 否则此处直接报 ORA- 并终止)
ALTER SESSION SET CONTAINER = &PDB_NAME;

-- 创建表空间 (幂等)
DECLARE
    v_sql VARCHAR2(4000);
BEGIN
    v_sql := 'CREATE TABLESPACE dherp
    DATAFILE
        ''/data/oracle/oradata/&ORACLE_SID/data00.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data01.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data02.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data03.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data04.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data05.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data06.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data07.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data08.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data09.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''/data/oracle/oradata/&ORACLE_SID/data10.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M
    EXTENT MANAGEMENT LOCAL
    SEGMENT SPACE MANAGEMENT AUTO';
    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('表空间 dherp 创建完成');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1543 THEN
            DBMS_OUTPUT.PUT_LINE('表空间 dherp 已存在, 跳过');
        ELSE
            RAISE;
        END IF;
END;
/

-- 创建用户 (幂等)
DECLARE
    v_sql VARCHAR2(4000);
BEGIN
    v_sql := 'CREATE USER &APP_USER IDENTIFIED BY "&APP_PASSWORD"
    DEFAULT TABLESPACE dherp
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON dherp';
    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('用户 &APP_USER 创建完成');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1920 THEN
            DBMS_OUTPUT.PUT_LINE('用户 &APP_USER 已存在, 跳过');
        ELSE
            RAISE;
        END IF;
END;
/

-- 授权 (幂等: GRANT 重复执行不报错)
GRANT CONNECT, RESOURCE TO &APP_USER;
GRANT CREATE SESSION TO &APP_USER;
GRANT CREATE TABLE TO &APP_USER;
GRANT CREATE VIEW TO &APP_USER;
GRANT CREATE ANY PROCEDURE TO &APP_USER;
GRANT EXECUTE ANY PROCEDURE TO &APP_USER;
GRANT UNLIMITED TABLESPACE TO &APP_USER;

-- 创建目录对象 (幂等: CREATE OR REPLACE)
CREATE OR REPLACE DIRECTORY oracle_dumps AS '/data/oracle/oracle_dumps';
GRANT READ, WRITE ON DIRECTORY oracle_dumps TO &APP_USER;

PROMPT ==========================================
PROMPT 表空间和用户创建完成
PROMPT ==========================================
