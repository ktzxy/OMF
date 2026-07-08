--===============================================================================
-- OMF 初始化脚本: 创建表空间和用户
-- 基于原始 createtabelspace.sql 标准化
--===============================================================================

WHENEVER SQLERROR CONTINUE;

-- 切换到 PDB
ALTER SESSION SET CONTAINER = &PDB_NAME;

-- 创建表空间
CREATE TABLESPACE dherp
    DATAFILE
        '/data/oracle/oradata/&ORACLE_SID/data00.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data01.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data02.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data03.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data04.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data05.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data06.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data07.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data08.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data09.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M,
        '/data/oracle/oradata/&ORACLE_SID/data10.dbf' SIZE 1G AUTOEXTEND ON NEXT 500M
    EXTENT MANAGEMENT LOCAL
    SEGMENT SPACE MANAGEMENT AUTO;

-- 创建用户
CREATE USER &APP_USER IDENTIFIED BY "&APP_PASSWORD"
    DEFAULT TABLESPACE dherp
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON dherp;

-- 授权
GRANT CONNECT, RESOURCE TO &APP_USER;
GRANT CREATE SESSION TO &APP_USER;
GRANT CREATE TABLE TO &APP_USER;
GRANT CREATE VIEW TO &APP_USER;
GRANT CREATE ANY PROCEDURE TO &APP_USER;
GRANT EXECUTE ANY PROCEDURE TO &APP_USER;
GRANT UNLIMITED TABLESPACE TO &APP_USER;

-- 创建目录对象
CREATE OR REPLACE DIRECTORY oracle_dumps AS '/data/oracle/oracle_dumps';
GRANT READ, WRITE ON DIRECTORY oracle_dumps TO &APP_USER;

PROMPT ==========================================
PROMPT 表空间和用户创建完成
PROMPT ==========================================
