--===============================================================================
-- OMF 标准初始化模板: 创建【单个】应用模式(用户) + 表空间 + 目录对象
--
--   本文件由 omf sql init 按 APP_SCHEMAS 列表逐个调用, 每次注入不同
--   &APP_USER / &APP_PASSWORD / &APP_TABLESPACE / &APP_DATA_DIR。
--
--   注意: 文件名以 '_' 开头, 会被 omf sql run --all / sql_scan 自动跳过,
--         避免被当成普通 init 脚本误执行(它由 sql init 显式循环调用)。
--
-- 可配置项 (conf/omf.conf):
--   APP_SCHEMAS         模式列表(空格分隔), 如 "dherp lsdherp miserp"
--   <大写名>_USER       覆盖 Oracle 用户名 (默认=模式名)
--   <大写名>_PASSWORD   覆盖密码           (默认=全局 APP_PASSWORD)
--   <大写名>_TABLESPACE 覆盖表空间名       (默认=模式名)
--   <大写名>_DATA_DIR   覆盖数据文件目录   (默认=${ORACLE_DATA}/${ORACLE_SID}/<模式名>)
--   在 Oracle 中 "模式(Schema)" 等同于 "用户(User)"。
--
-- 幂等: 用 PL/SQL EXECUTE IMMEDIATE 吞掉 ORA-01543(表空间已存在) 与
--       ORA-01920(用户已存在); 其余真实错误仍照常抛出。
--===============================================================================

-- 切换到目标 PDB (PDB 必须 OPEN)
ALTER SESSION SET CONTAINER = &PDB_NAME;

-- 1) 创建表空间 (幂等)
--    数据文件落在 &APP_DATA_DIR (每模式独立子目录, 避免多模式同名文件冲突 ORA-01537)
--    数据文件个数/大小由 &APP_DATAFILES (默认 4) / &APP_DATAFILE_SIZE_MB (默认 1024) 控制,
--    由 omf sql init 注入 (conf 可覆盖 <大写名>_DATAFILES / <大写名>_DATAFILE_SIZE_MB), 适配大小库。
DECLARE
    v_sql VARCHAR2(4000);
    v_n   NUMBER;
    v_i   NUMBER;
    v_df  VARCHAR2(4000);
BEGIN
    -- 数据文件个数: 钳制 1~16, 防误配过多
    v_n := LEAST(GREATEST(&APP_DATAFILES, 1), 16);
    -- 拼接 DATAFILE 子句: data00.dbf ~ data(N-1).dbf, 每个 SIZE 按配置 (MB) 且 AUTOEXTEND
    v_df := '';
    FOR v_i IN 0 .. v_n - 1 LOOP
        IF v_i > 0 THEN v_df := v_df || ','; END IF;
        v_df := v_df || ' ''' || '&APP_DATA_DIR/data' || LPAD(v_i, 2, '0') || '.dbf' ||
                ''' SIZE ' || &APP_DATAFILE_SIZE_MB || 'M AUTOEXTEND ON NEXT 500M';
    END LOOP;
    v_sql := 'CREATE TABLESPACE &APP_TABLESPACE DATAFILE' || v_df ||
             ' EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';
    EXECUTE IMMEDIATE v_sql;
    DBMS_OUTPUT.PUT_LINE('表空间 &APP_TABLESPACE 创建完成 (数据目录 &APP_DATA_DIR, ' || v_n || ' 个数据文件, 每 ' || &APP_DATAFILE_SIZE_MB || 'M)');
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
