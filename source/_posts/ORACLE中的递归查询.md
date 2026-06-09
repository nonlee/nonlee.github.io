---
title: ORACLE中的递归查询
date: 2026-06-09 17:41:06
tags: [sql，递归查询]
top: 11
categories: sql
---

在关系型数据库中，处理具有层级或树状结构的数据（如组织架构、物料清单、分类目录等）是一项常见需求。Oracle 数据库提供了强大的递归查询机制，允许开发者在单条 SQL 语句中遍历这种层次关系。

目前，Oracle 支持两种主流的递归查询方式：
- **`CONNECT BY` 层次查询**：Oracle 专有的传统语法，语法简洁，在特定场景下性能优异。
- **`WITH RECURSIVE` 递归公用表表达式 (CTE)**：符合 ANSI SQL 标准的现代语法，自 Oracle 11g Release 2 起引入，具有更好的可移植性和灵活性。
<!-- more -->

在oracle数据库中，有如下表：

```sql
-- 1. 创建表结构（如果表已存在，请注释掉或删除此段）
CREATE TABLE tmp_rule (
    RECEIVERS      VARCHAR2(4000),
    INCLUDEPATHS   VARCHAR2(4000),
    ALARM_MODE     VARCHAR2(50)
);

-- 2. 插入 5 条模拟数据 (使用 UNION ALL 方式，这是 Oracle 最常用的批量插入写法)
INSERT INTO tmp_rule (RECEIVERS, INCLUDEPATHS, ALARM_MODE)
SELECT 'zhangsan;lisi',
       'path_a001;path_b002',
       '短信'
FROM DUAL
UNION ALL
SELECT 'wangwu;zhaoliu;sunqi',
       'server_192.168.1.10;server_192.168.1.11;server_192.168.1.12',
       '邮件'
FROM DUAL
UNION ALL
SELECT 'zhouba;wujiu',
       'app_module_x;app_module_y',
       '电话'
FROM DUAL
UNION ALL
SELECT 'zhengshi;wanger;mazi',
       'log_dir_01;log_dir_02;log_dir_03',
       '短信'
FROM DUAL
UNION ALL
SELECT 'liuyi',
       'single_path_unique_id',
       '微信'
FROM DUAL;
```

想要将字段RECEIVERS和INCLUDEPATHS按照分号;拆分后一一对应，形成一个新的表，使用递归查询 connect by level 的sql如下下：

```sql
WITH t_base AS (
	-- 1 基础数据
	SELECT rowid AS rid,receivers,includepaths,alarm_mode   FROM tmp1_alarm_rule_new
),
t_receivers AS (
	-- 2 拆分receivers
	SELECT rid ,
	REGEXP_SUBSTR(receivers,'[^;]+',1,LEVEL ) AS spilt_receive 
	FROM t_base
	CONNECT BY LEVEL <= LENGTH(receivers) - LENGTH (REGEXP_REPLACE(receivers,';'))+1
	AND PRIOR rid = RID 
	AND PRIOR SYS_GUID() IS NOT NULL  
),
t_includepaths AS (
	-- 3 拆分includepaths
	SELECT rid ,
	REGEXP_SUBSTR(includepaths,'[^;]+',1,LEVEL ) AS spilt_includepath 
	FROM t_base
	CONNECT BY LEVEL <= LENGTH(includepaths) - LENGTH (REGEXP_REPLACE(includepaths,';'))+1
	AND PRIOR rid = RID 
	AND PRIOR SYS_GUID() IS NOT NULL  
) 
-- 4 将拆分的结果进行笛卡尔积
SELECT b.spilt_receive,c.spilt_includepath,a.ALARM_MODE FROM t_base a
JOIN t_receivers b ON a.rid = b.rid
JOIN t_includepaths c ON a.rid = c.rid  ;
```

对这个sql的说明如下，写法适用于Oracle 10g 及以上版本：

1. **`t_base` ：首先获取原始表数据，并提取 `ROWID`。这是关键锚点，确保我们在后续拆分时不会把 A 行的接收人和 B 行的路径搞混。

2. `t_recv_split` & `t_path_split`：这两个子查询分别负责“切分”工作。它们利用 CONNECT BY LEVEL将字符串切成多行。注意这里的 `PRIOR rid = rid` 和 `PRIOR SYS_GUID() IS NOT NULL` 是 Oracle 中防止层级查询在多行数据上发生混乱的标准写法。

3. 最终 SELECT：这里使用了标准的 JOIN ... ON ...。因为 t_recv_split 和 t_path_split 都只包含 rid 和拆分后的值，当它们通过 rid 关联回 t_base 时，Oracle 会自动执行 笛卡尔积。 例如：对于 rid='AAA' 的行，如果有 4 个接收人和 3 个路径，数据库会自动生成 4×3=12 种组合。

4. 对`CONNECT BY LEVEL <= LENGTH(...) - LENGTH(REPLACE(...)) + 1` 的作用为我要拆成几行：

   这是层级查询的终止条件。Oracle 的 CONNECT BY会不断递归生成新行，直到这个条件不再满足为止。我们需要告诉数据库：对于当前这一行数据，到底有多少个分号分隔的值？

   原理推导：

   假设字符串是 'A;B;C'。

   LENGTH('A;B;C') = 5。

   REPLACE('A;B;C', ';', '') 变成了 'ABC'，长度为 3。

   两者相减：5−3=2 。这说明有 2 个分号。

   值的数量 = 分隔符数量 + 1。所以公式是 2+1=3 。
   结果： 数据库知道这一行需要生成 3 层数据（Level 1, Level 2, Level 3），分别对应 A、B、C。

5. AND PRIOR rid = rid
   作用： “自连接”锚点，锁定当前行。
   这是最关键的一句，防止数据“串台”。
   为什么需要它？
   CONNECT BY 本质上是一种树形遍历（Hierarchical Query）。如果不加限制，Oracle 会把表里所有的行都看作一棵大树的一部分。比如第 1 行的 'A' 可能会错误地连接到第 2 行的 'X' 下面去。
   原理：
   PRIOR 关键字代表“上一级（父节点）”的数据。
   rid 是我们预先取出的 ROWID（物理行唯一标识）。
   PRIOR rid = rid 的意思是：下一级的数据，其 ROWID 必须和上一级的 ROWID 相同。
   效果： 这强制规定了递归只能在 同一行内部 进行。第 1 行只会在第 1 行内部拆分，绝对不会跑到第 2 行去。

6. AND PRIOR SYS_GUID() IS NOT NULL 
作用： 打破死循环的“欺骗性”条件。这是一个在 Oracle 单表层级查询中非常著名的“黑科技”写     法。为什么要加它？
如果你只写 PRIOR rid = rid，Oracle 优化器会发现：既然父节点的 ID 等于子节点的 ID，那么这就构成了一个无限循环（A 的父亲是 A，A 的儿子也是 A...）。为了防止这种逻辑上的死循环报错，或者为了强制 Oracle 放弃使用基于索引的快速路径（Index Fast Full Scan）而改用全表扫描式的递归，我们需要引入一个 “永远不相等” 或 “永远为真但无法预测” 的条件来混淆优化器。
原理：
SYS_GUID() 每次调用都会生成一个全新的、唯一的随机字符串（UUID）。
PRIOR SYS_GUID() 获取的是上一层生成的 UUID。
当前层的 SYS_GUID() 肯定不等于上一层的 UUID。
虽然逻辑上我们写的是 IS NOT NULL（GUID 永远不会是 NULL，所以这个条件恒为真），但它的存在告诉 Oracle 引擎：“嘿，每一层都有一个独特的、不可预测的值，别试图把它们合并或者建立错误的索引连接。”

sql的另外一个写法，性能不如上面的sql，但是通用性更好

```
select REGEXP_SUBSTR(RECEIVERS, '[^;]+', 1, L) AS RECEIVERS,alarm_mode,
               INCLUDEPATHS
          from (select REGEXP_SUBSTR(INCLUDEPATHS, '[^;]+', 1, L) AS INCLUDEPATHS,
                       RECEIVERS,
                       alarm_mode 
                  from tmp_rule,
                       (SELECT LEVEL L FROM DUAL CONNECT BY LEVEL <= 1000)
                 WHERE L(+) <= LENGTH(INCLUDEPATHS) -
                       LENGTH(REPLACE(INCLUDEPATHS, ';')) + 1) tt,
               (SELECT LEVEL L FROM DUAL CONNECT BY LEVEL <= 1000)
         WHERE L(+) <=
               LENGTH(RECEIVERS) - LENGTH(REPLACE(RECEIVERS, ';')) + 1 ;
```



在mysql8的版本中，不支持connect by level的写法，使用标准递归CTE的写法

```
-- 1. 创建表结构 (如果表已存在，请注释掉或删除此段)
CREATE TABLE IF NOT EXISTS `tmp_rule` (
    `RECEIVERS`    VARCHAR(4000),
    `INCLUDEPATHS` VARCHAR(4000),
    `ALARM_MODE`   VARCHAR(50)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 2. 插入 5 条模拟数据 (使用 MySQL 标准的多行 VALUES 插入语法)
INSERT INTO `tmp_rule` (`RECEIVERS`, `INCLUDEPATHS`, `ALARM_MODE`) VALUES
('zhangsan;lisi', 'path_a001;path_b002', '短信'),
('wangwu;zhaoliu;sunqi', 'server_192.168.1.10;server_192.168.1.11;server_192.168.1.12', '邮件'),
('zhouba;wujiu', 'app_module_x;app_module_y', '电话'),
('zhengshi;wanger;mazi', 'log_dir_01;log_dir_02;log_dir_03', '短信'),
('liuyi', 'single_path_unique_id', '微信');
```



```
-- 递归查询
WITH RECURSIVE 
-- 1. 基础数据准备 (使用 ROW_NUMBER() 动态生成唯一标识 rid)
t_base AS (
    SELECT 
        ROW_NUMBER() OVER() AS rid, 
        receivers, 
        includepaths, 
        alarm_mode 
    FROM tmp_rule
),

-- 2. 递归拆分 RECEIVERS
t_receivers AS (
    -- 【锚点成员】：提取第一个分号前的内容
    SELECT 
        rid,
        CASE 
            WHEN LOCATE(';', receivers) > 0 THEN SUBSTRING(receivers, 1, LOCATE(';', receivers) - 1)
            ELSE receivers 
        END AS spilt_receive,
        CASE 
            WHEN LOCATE(';', receivers) > 0 THEN SUBSTRING(receivers, LOCATE(';', receivers) + 1)
            ELSE NULL 
        END AS remaining_str
    FROM t_base

    UNION ALL

    -- 【递归成员】：从剩余字符串中继续提取
    SELECT 
        rid,
        CASE 
            WHEN LOCATE(';', remaining_str) > 0 THEN SUBSTRING(remaining_str, 1, LOCATE(';', remaining_str) - 1)
            ELSE remaining_str 
        END AS spilt_receive,
        CASE 
            WHEN LOCATE(';', remaining_str) > 0 THEN SUBSTRING(remaining_str, LOCATE(';', remaining_str) + 1)
            ELSE NULL 
        END AS remaining_str
    FROM t_receivers
    WHERE remaining_str IS NOT NULL AND remaining_str <> '' -- 终止条件：没有剩余字符串时停止
),

-- 3. 递归拆分 INCLUDEPATHS (逻辑同上)
t_includepaths AS (
    -- 【锚点成员】
    SELECT 
        rid,
        CASE 
            WHEN LOCATE(';', includepaths) > 0 THEN SUBSTRING(includepaths, 1, LOCATE(';', includepaths) - 1)
            ELSE includepaths 
        END AS spilt_includepath,
        CASE 
            WHEN LOCATE(';', includepaths) > 0 THEN SUBSTRING(includepaths, LOCATE(';', includepaths) + 1)
            ELSE NULL 
        END AS remaining_str
    FROM t_base

    UNION ALL

    -- 【递归成员】
    SELECT 
        rid,
        CASE 
            WHEN LOCATE(';', remaining_str) > 0 THEN SUBSTRING(remaining_str, 1, LOCATE(';', remaining_str) - 1)
            ELSE remaining_str 
        END AS spilt_includepath,
        CASE 
            WHEN LOCATE(';', remaining_str) > 0 THEN SUBSTRING(remaining_str, LOCATE(';', remaining_str) + 1)
            ELSE NULL 
        END AS remaining_str
    FROM t_includepaths
    WHERE remaining_str IS NOT NULL AND remaining_str <> ''
)

-- 4. 将拆分的结果进行笛卡尔积
SELECT 
    b.spilt_receive, 
    c.spilt_includepath, 
    a.alarm_mode 
FROM t_base a
JOIN t_receivers b ON a.rid = b.rid
JOIN t_includepaths c ON a.rid = c.rid;
```

