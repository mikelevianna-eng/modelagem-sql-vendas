-- =====================================================================
-- STAGING
-- =====================================================================

-- Havendo ponto e virgula juntos, o ponto e separador de milhar.
-- Havendo so ponto, ele e decimal. Apagar todo ponto sem verificar
-- transformaria 89.90 em 8990.
CREATE OR REPLACE MACRO to_num(v) AS TRY_CAST(
    CASE
        WHEN contains(trim(replace(replace(CAST(v AS VARCHAR), 'R$', ''), ' ', '')), '.')
         AND contains(trim(replace(replace(CAST(v AS VARCHAR), 'R$', ''), ' ', '')), ',')
        THEN replace(replace(trim(replace(replace(CAST(v AS VARCHAR), 'R$', ''), ' ', '')), '.', ''), ',', '.')
        ELSE replace(trim(replace(replace(CAST(v AS VARCHAR), 'R$', ''), ' ', '')), ',', '.')
    END AS DOUBLE);

-- O formato e escolhido pelo padrao do texto, e nao por tentativa em
-- cadeia. O strptime aceita '%Y' com dois digitos, entao '05-03-25'
-- seria lido como ano 5 se a data curta fosse testada depois da ISO.
CREATE OR REPLACE MACRO to_date_br(v) AS TRY_CAST(
    CASE
        WHEN regexp_matches(trim(CAST(v AS VARCHAR)), '^\d{2}/\d{2}/\d{4}$')
            THEN try_strptime(trim(CAST(v AS VARCHAR)), '%d/%m/%Y')
        WHEN regexp_matches(trim(CAST(v AS VARCHAR)), '^\d{4}-\d{2}-\d{2}$')
            THEN try_strptime(trim(CAST(v AS VARCHAR)), '%Y-%m-%d')
        WHEN regexp_matches(trim(CAST(v AS VARCHAR)), '^\d{2}-\d{2}-\d{2}$')
            THEN try_strptime(trim(CAST(v AS VARCHAR)), '%d-%m-%y')
    END AS DATE);

CREATE OR REPLACE MACRO norm_txt(v) AS
    nullif(regexp_replace(trim(CAST(v AS VARCHAR)), '\s+', ' ', 'g'), '');

-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stg_produtos AS
SELECT
    codigo_produto,
    norm_txt(descricao)          AS descricao,
    norm_txt(categoria)          AS categoria,
    norm_txt(unidade)            AS unidade,
    to_num(custo_unitario)       AS custo_unitario,
    to_num(preco_tabela)         AS preco_tabela,
    upper(trim(ativo)) = 'S'     AS ativo
FROM raw_produtos;

CREATE OR REPLACE VIEW stg_clientes AS
SELECT
    codigo_cliente,
    norm_txt(razao_social)                        AS razao_social,
    nullif(regexp_replace(cnpj, '\D', '', 'g'), '') AS cnpj,
    norm_txt(segmento)                            AS segmento,
    norm_txt(regiao)                              AS regiao,
    trim(vendedor)                                AS cod_vendedor,
    to_date_br(data_cadastro)                     AS data_cadastro,
    to_num(limite_credito)                        AS limite_credito
FROM raw_clientes;

-- Deduplicacao pela chave de negocio do ERP e exclusao de cancelados.
-- Quantidade negativa e devolucao lancada sem sinalizacao propria.
CREATE OR REPLACE VIEW stg_vendas AS
WITH base AS (
    SELECT
        CAST(numero_pedido AS INTEGER)   AS numero_pedido,
        CAST(sequencia_item AS INTEGER)  AS sequencia_item,
        to_date_br(data_pedido)          AS data_pedido,
        codigo_cliente,
        codigo_produto,
        CAST(quantidade AS INTEGER)      AS quantidade,
        to_num(preco_unitario)           AS preco_unitario,
        to_num(desconto_pct)             AS desconto_pct,
        to_num(frete_cobrado)            AS frete_cobrado,
        to_num(custo_frete_real)         AS custo_frete_real,
        trim(vendedor)                   AS cod_vendedor,
        upper(trim(status))              AS status,
        -- A chave pedido mais item e unica no ERP, entao repeticao e
        -- falha de exportacao. O criterio de desempate e explicito para
        -- o resultado nao depender da ordem em que o arquivo foi lido.
        row_number() OVER (
            PARTITION BY numero_pedido, sequencia_item
            ORDER BY CASE WHEN CAST(quantidade AS INTEGER) < 0 THEN 1 ELSE 0 END,
                     codigo_cliente
        ) AS ocorrencia
    FROM raw_vendas
)
SELECT
    * EXCLUDE (ocorrencia),
    CASE WHEN quantidade < 0 THEN 'DEVOLUCAO' ELSE 'VENDA' END AS tipo_operacao
FROM base
WHERE ocorrencia = 1
  AND status <> 'CANCELADO'
  AND data_pedido IS NOT NULL;

-- =====================================================================
-- DIMENSOES
-- =====================================================================

CREATE OR REPLACE TABLE dim_produto AS
SELECT
    row_number() OVER (ORDER BY codigo_produto) AS sk_produto,
    codigo_produto,
    descricao,
    categoria,
    unidade,
    custo_unitario,
    preco_tabela,
    custo_unitario IS NOT NULL AS custo_confiavel,
    ativo
FROM stg_produtos;

CREATE OR REPLACE TABLE dim_cliente AS
SELECT
    row_number() OVER (ORDER BY codigo_cliente) AS sk_cliente,
    codigo_cliente,
    razao_social,
    cnpj,
    segmento,
    regiao,
    data_cadastro
FROM stg_clientes
UNION ALL
SELECT 0, 'NAO_IDENTIFICADO', 'Cliente nao identificado', NULL, NULL, NULL, NULL;

CREATE OR REPLACE TABLE dim_vendedor AS
SELECT
    row_number() OVER (ORDER BY cod_vendedor) AS sk_vendedor,
    cod_vendedor,
    CASE cod_vendedor
        WHEN 'V01' THEN 'Rogerio Antunes'
        WHEN 'V02' THEN 'Simone Klein'
        WHEN 'V03' THEN 'Tarcisio Bueno'
        ELSE 'Nao informado'
    END AS nome_vendedor,
    CASE cod_vendedor
        WHEN 'V01' THEN 0.030
        WHEN 'V02' THEN 0.035
        WHEN 'V03' THEN 0.028
        ELSE 0.032
    END AS taxa_comissao
FROM (SELECT DISTINCT cod_vendedor FROM stg_vendas WHERE cod_vendedor IS NOT NULL);

CREATE OR REPLACE TABLE dim_tempo AS
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER) AS sk_tempo,
    d                                      AS data,
    year(d)                                AS ano,
    month(d)                               AS mes,
    strftime(d, '%Y-%m')                   AS ano_mes,
    quarter(d)                             AS trimestre,
    dayofweek(d)                           AS dia_semana,
    strftime(d, '%A')                      AS nome_dia,
    dayofweek(d) IN (0, 6)                 AS fim_de_semana
FROM (
    SELECT (lim.inicio + to_days(CAST(g.n AS INTEGER)))::DATE AS d
    FROM (SELECT min(data_pedido) AS inicio, max(data_pedido) AS fim FROM stg_vendas) AS lim,
         generate_series(
             0,
             (SELECT datediff('day', min(data_pedido), max(data_pedido)) FROM stg_vendas)
         ) AS g(n)
);

-- =====================================================================
-- FATO
-- =====================================================================

CREATE OR REPLACE TABLE fct_vendas AS
SELECT
    v.numero_pedido,
    v.sequencia_item,
    t.sk_tempo,
    coalesce(c.sk_cliente, 0)  AS sk_cliente,
    p.sk_produto,
    ve.sk_vendedor,
    v.tipo_operacao,
    v.quantidade,
    v.preco_unitario,
    v.desconto_pct,

    -- medidas aditivas
    round(v.preco_unitario * v.quantidade, 2)                       AS receita_mercadoria,
    round(v.preco_unitario * v.quantidade + v.frete_cobrado, 2)     AS receita_total,
    round(p.custo_unitario * v.quantidade, 2)                       AS custo_produto,
    round(v.custo_frete_real, 2)                                    AS custo_entrega,
    round(v.preco_unitario * v.quantidade * ve.taxa_comissao, 2)    AS custo_comissao,
    round(v.custo_frete_real - v.frete_cobrado, 2)                  AS frete_subsidiado,

    -- margem bruta e o que o ERP nao mostra
    CASE WHEN p.custo_confiavel
         THEN round(v.preco_unitario * v.quantidade - p.custo_unitario * v.quantidade, 2)
    END AS margem_bruta,
    CASE WHEN p.custo_confiavel
         THEN round(
              v.preco_unitario * v.quantidade + v.frete_cobrado
            - p.custo_unitario * v.quantidade
            - v.custo_frete_real
            - v.preco_unitario * v.quantidade * ve.taxa_comissao, 2)
    END AS margem_contribuicao,

    p.custo_confiavel
FROM stg_vendas v
JOIN dim_produto  p  ON p.codigo_produto = v.codigo_produto
JOIN dim_tempo    t  ON t.data           = v.data_pedido
JOIN dim_vendedor ve ON ve.cod_vendedor  = v.cod_vendedor
LEFT JOIN dim_cliente c ON c.codigo_cliente = v.codigo_cliente;
