--===============================================================================
-- OMF 标准初始化脚本: 创建应用模式(用户) + 表空间 + 目录对象
--
-- 用途: 为后续的数据导入(impdp / sqlldr / 入库脚本)准备目标模式。
--       在 Oracle 中, "模式(Schema)"等同于"用户(User)" —— 创建用户即创建其模式,
--       因此无需单独的"模式名"配置: 修改 APP_USER 即同时设定了用户名与模式名。
--
-- 可配置项 (在 conf/omf.conf 中修改, 无需改动本脚本):
--   APP_USER       用户名 / 模式名         (默认 dherp)
--   APP_PASSWORD   用户密码               (默认 dherp_skzy)
--   APP_TABLESPACE 表空间名              (默认 dherp)
--   PDB_NAME       目标 PDB              (默认 ARTERYPDB)
--   ORACLE_SID     用于推导数据文件路径   (默认 ARTERY)
--
-- 幂等: 用 PL/SQL EXECUTE IMMEDIATE 吞掉
--        ORA-01543 (表空间已存在) 与 ORA-01920 (用户已存在), 重跑不再误报;
--        其余真实错误仍照常抛出, 并被 OMF 的三重检测(退出码 + grep ORA-)捕获。
--===============================================================================

-- 切换到目标 PDB (PDB 必须 OPEN, 否则此处直接报错并终止)
ALTER SESSION SET CONTAINER = &PDB_NAME;

-- 1) 创建表空间 (幂等)
DECLARE
    v_sql VARCHAR2(4000);
BEGIN
    v_sql := 'CREATE TABLESPACE &APP_TABLESPACE
    DATAFILE
        ''&ORACLE_DATA/&ORACLE_SID/data00.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data01.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data02.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data03.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data04.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data05.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data06.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data07.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data08.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data09.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M,
        ''&ORACLE_DATA/&ORACLE_SID/data10.dbf'' SIZE 1G AUTOEXTEND ON NEXT 500M
    EXTENT MANAGEMENT LOCAL
    SEGMENT SPACE MANAGEMENT AUTO';
    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('表空间 &APP_TABLESPACE 创建完成');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1543 THEN
            DBMS_OUTPUT.PUT_LINE('表空间 &APP_TABLESPACE 已存在, 跳过');
        ELSE
            RAISE;
        END IF;
END;
/

-- 2) 创建用户/模式 (幂等)
DECLARE
    v_sql VARCHAR2(4000);
BEGIN
    v_sql := 'CREATE USER &APP_USER IDENTIFIED BY "&APP_PASSWORD"
    DEFAULT TABLESPACE &APP_TABLESPACE
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON &APP_TABLESPACE';
    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('用户/模式 &APP_USER 创建完成');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1920 THEN
            DBMS_OUTPUT.PUT_LINE('用户/模式 &APP_USER 已存在, 跳过');
        ELSE
            RAISE;
        END IF;
END;
/

-- 3) 授权 (幂等: GRANT 重复执行不报错)
--    作为数据导入的目标模式, 通常需要: 连接、建表/视图/序列/过程/触发器/同义词、无限表空间配额
GRANT CONNECT, RESOURCE TO &APP_USER;
GRANT CREATE SESSION        TO &APP_USER;
GRANT CREATE TABLE          TO &APP_USER;
GRANT CREATE VIEW           TO &APP_USER;
GRANT CREATE SEQUENCE       TO &APP_USER;
GRANT CREATE PROCEDURE      TO &APP_USER;
GRANT CREATE TRIGGER        TO &APP_USER;
GRANT CREATE SYNONYM        TO &APP_USER;
GRANT UNLIMITED TABLESPACE  TO &APP_USER;

-- 4) 创建目录对象 (幂等: CREATE OR REPLACE), 供数据泵等导入工具使用
--    路径来自 &ORACLE_DUMP_DIR (由框架注入, 默认 /data/oracle/oracle_dumps,
--    对应的 OS 目录由 omf sql init 自动创建并 chown oracle)
CREATE OR REPLACE DIRECTORY oracle_dumps AS '&ORACLE_DUMP_DIR';
GRANT READ, WRITE ON DIRECTORY oracle_dumps TO &APP_USER;

PROMPT ==========================================
PROMPT 应用模式(&APP_USER)初始化完成
PROMPT ==========================================
