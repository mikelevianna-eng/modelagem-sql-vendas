-- =====================================================================
-- 01. Onde a margem se forma e onde ela se perde
-- =====================================================================
CREATE OR REPLACE VIEW an_categoria AS
SELECT
    p.categoria,
    count(DISTINCT f.numero_pedido)                       AS pedidos,
    round(sum(f.receita_total), 2)                        AS receita,
    round(sum(f.custo_produto), 2)                        AS custo_produto,
    round(sum(f.custo_entrega), 2)                        AS custo_entrega,
    round(sum(f.custo_comissao), 2)                       AS custo_comissao,
    round(sum(f.frete_subsidiado), 2)                     AS frete_subsidiado,
    round(sum(f.margem_bruta), 2)                         AS margem_bruta,
    round(sum(f.margem_contribuicao), 2)                  AS margem_contribuicao,
    round(100.0 * sum(f.margem_contribuicao)
               / nullif(sum(f.receita_total), 0), 1)      AS margem_pct,
    round(100.0 * sum(f.receita_total)
               / sum(sum(f.receita_total)) OVER (), 1)    AS participacao_pct,
    CASE
        WHEN sum(f.margem_contribuicao) < 0 THEN 'Prejuizo'
        WHEN 100.0 * sum(f.margem_contribuicao) / nullif(sum(f.receita_total), 0) < 10 THEN 'Critica'
        WHEN 100.0 * sum(f.margem_contribuicao) / nullif(sum(f.receita_total), 0) < 20 THEN 'Atencao'
        ELSE 'Saudavel'
    END                                                   AS situacao
FROM fct_vendas f
JOIN dim_produto p ON p.sk_produto = f.sk_produto
WHERE f.custo_confiavel
GROUP BY p.categoria
ORDER BY margem_contribuicao;

-- =====================================================================
-- 02. Da receita ao que sobra, em degraus
-- =====================================================================
CREATE OR REPLACE VIEW an_cascata AS
WITH t AS (
    SELECT
        sum(receita_total)      AS receita,
        sum(custo_produto)      AS mercadoria,
        sum(custo_entrega)      AS entrega,
        sum(custo_comissao)     AS comissao,
        sum(margem_contribuicao) AS margem
    FROM fct_vendas WHERE custo_confiavel
)
SELECT 1 AS ordem, 'Receita'    AS etapa, round(receita, 2)     AS valor FROM t
UNION ALL SELECT 2, 'Mercadoria', round(-mercadoria, 2) FROM t
UNION ALL SELECT 3, 'Entrega',    round(-entrega, 2)    FROM t
UNION ALL SELECT 4, 'Comissao',   round(-comissao, 2)   FROM t
UNION ALL SELECT 5, 'Margem',     round(margem, 2)      FROM t
ORDER BY ordem;

-- =====================================================================
-- 03. Curva ABC de clientes cruzada com rentabilidade
-- =====================================================================
CREATE OR REPLACE VIEW an_clientes_abc AS
WITH por_cliente AS (
    SELECT
        c.codigo_cliente,
        c.razao_social,
        c.segmento,
        c.regiao,
        count(DISTINCT f.numero_pedido)        AS pedidos,
        sum(f.receita_total)                   AS receita,
        sum(f.margem_contribuicao)             AS margem,
        sum(f.frete_subsidiado)                AS frete_subsidiado,
        avg(f.desconto_pct)                    AS desconto_medio
    FROM fct_vendas f
    JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
    WHERE f.custo_confiavel AND c.codigo_cliente <> 'NAO_IDENTIFICADO'
    GROUP BY ALL
),
acumulado AS (
    SELECT
        *,
        sum(receita) OVER (ORDER BY receita DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / sum(receita) OVER ()                       AS receita_acumulada,
        row_number() OVER (ORDER BY receita DESC)        AS posicao
    FROM por_cliente
)
SELECT
    posicao,
    razao_social,
    segmento,
    regiao,
    pedidos,
    round(receita, 2)                          AS receita,
    round(receita / pedidos, 2)                AS ticket_medio,
    round(margem, 2)                           AS margem,
    round(100.0 * margem / nullif(receita, 0), 1) AS margem_pct,
    round(frete_subsidiado, 2)                 AS frete_subsidiado,
    round(desconto_medio, 1)                   AS desconto_medio,
    round(100.0 * receita_acumulada, 1)        AS receita_acumulada_pct,
    CASE WHEN receita_acumulada <= 0.80 THEN 'A'
         WHEN receita_acumulada <= 0.95 THEN 'B'
         ELSE 'C' END                          AS classe_abc
FROM acumulado
ORDER BY posicao;

-- =====================================================================
-- 04. Os maiores clientes rendem menos que a media da carteira
-- =====================================================================
CREATE OR REPLACE VIEW an_clientes_criticos AS
WITH media AS (
    SELECT 100.0 * sum(margem_contribuicao) / sum(receita_total) AS margem_carteira
    FROM fct_vendas WHERE custo_confiavel
)
SELECT
    a.classe_abc,
    a.razao_social,
    a.segmento,
    a.receita,
    a.margem,
    a.margem_pct,
    round(m.margem_carteira, 1)                       AS margem_carteira_pct,
    round(a.margem_pct - m.margem_carteira, 1)        AS diferenca_pp,
    a.desconto_medio,
    round(a.receita * (m.margem_carteira - a.margem_pct) / 100, 2) AS margem_nao_realizada
FROM an_clientes_abc a
CROSS JOIN media m
WHERE a.classe_abc IN ('A', 'B')
  AND a.margem_pct < m.margem_carteira
ORDER BY margem_nao_realizada DESC;

-- =====================================================================
-- 05. O ponto em que o desconto deixa de compensar
-- =====================================================================
CREATE OR REPLACE VIEW an_desconto AS
SELECT
    CASE
        WHEN desconto_pct < 5  THEN '1. ate 5%'
        WHEN desconto_pct < 10 THEN '2. 5 a 10%'
        WHEN desconto_pct < 15 THEN '3. 10 a 15%'
        WHEN desconto_pct < 20 THEN '4. 15 a 20%'
        ELSE '5. acima de 20%'
    END                                                   AS faixa,
    count(*)                                              AS itens,
    round(sum(receita_total), 2)                          AS receita,
    round(100.0 * sum(receita_total)
               / sum(sum(receita_total)) OVER (), 1)      AS participacao_pct,
    round(sum(margem_contribuicao), 2)                    AS margem,
    round(100.0 * sum(margem_contribuicao)
               / nullif(sum(receita_total), 0), 1)        AS margem_pct
FROM fct_vendas
WHERE custo_confiavel
GROUP BY faixa
ORDER BY faixa;

-- =====================================================================
-- 06. Quanto a politica de frete gratis custa
-- =====================================================================
CREATE OR REPLACE VIEW an_frete AS
SELECT
    p.categoria,
    round(sum(f.receita_total), 2)                        AS receita,
    round(sum(f.custo_entrega), 2)                        AS custo_entrega,
    round(sum(f.custo_entrega - f.frete_subsidiado), 2)   AS frete_cobrado,
    round(sum(f.frete_subsidiado), 2)                     AS frete_absorvido,
    round(100.0 * sum(f.frete_subsidiado)
               / nullif(sum(f.receita_total), 0), 1)      AS absorvido_sobre_receita_pct,
    round(sum(f.margem_contribuicao), 2)                  AS margem,
    round(sum(f.margem_contribuicao) + sum(f.frete_subsidiado), 2) AS margem_sem_subsidio
FROM fct_vendas f
JOIN dim_produto p ON p.sk_produto = f.sk_produto
WHERE f.custo_confiavel
GROUP BY p.categoria
ORDER BY frete_absorvido DESC;

-- =====================================================================
-- 07. Evolucao mensal com variacao sobre o mes anterior
-- =====================================================================
CREATE OR REPLACE VIEW an_mensal AS
WITH mes AS (
    SELECT
        t.ano_mes,
        count(DISTINCT f.numero_pedido)  AS pedidos,
        sum(f.receita_total)             AS receita,
        sum(f.margem_contribuicao)       AS margem,
        sum(f.frete_subsidiado)          AS frete_absorvido
    FROM fct_vendas f
    JOIN dim_tempo t ON t.sk_tempo = f.sk_tempo
    WHERE f.custo_confiavel
    GROUP BY t.ano_mes
)
SELECT
    ano_mes,
    pedidos,
    round(receita, 2)                                        AS receita,
    round(receita / pedidos, 2)                              AS ticket_medio,
    round(margem, 2)                                         AS margem,
    round(100.0 * margem / nullif(receita, 0), 1)            AS margem_pct,
    round(frete_absorvido, 2)                                AS frete_absorvido,
    round(100.0 * (receita - lag(receita) OVER (ORDER BY ano_mes))
               / nullif(lag(receita) OVER (ORDER BY ano_mes), 0), 1) AS var_receita_pct,
    round(100.0 * (margem - lag(margem) OVER (ORDER BY ano_mes))
               / nullif(abs(lag(margem) OVER (ORDER BY ano_mes)), 0), 1) AS var_margem_pct,
    round(avg(100.0 * margem / nullif(receita, 0))
              OVER (ORDER BY ano_mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)
                                                             AS margem_pct_media_3m
FROM mes
ORDER BY ano_mes;

-- =====================================================================
-- 08. Produtos que vendem e dao prejuizo
-- =====================================================================
CREATE OR REPLACE VIEW an_produtos_prejuizo AS
SELECT
    p.codigo_produto,
    p.descricao,
    p.categoria,
    sum(f.quantidade)                                     AS quantidade,
    round(sum(f.receita_total), 2)                        AS receita,
    round(sum(f.margem_bruta), 2)                         AS margem_bruta,
    round(sum(f.margem_contribuicao), 2)                  AS margem_contribuicao,
    round(100.0 * sum(f.margem_contribuicao)
               / nullif(sum(f.receita_total), 0), 1)      AS margem_pct,
    round(avg(f.desconto_pct), 1)                         AS desconto_medio,
    round(sum(f.frete_subsidiado), 2)                     AS frete_absorvido
FROM fct_vendas f
JOIN dim_produto p ON p.sk_produto = f.sk_produto
WHERE f.custo_confiavel
GROUP BY ALL
HAVING sum(f.margem_contribuicao) < 0
   AND sum(f.receita_total) > 1000
ORDER BY margem_contribuicao;

-- =====================================================================
-- 09. Desempenho da equipe comercial
-- =====================================================================
CREATE OR REPLACE VIEW an_vendedor AS
SELECT
    v.nome_vendedor,
    round(100.0 * v.taxa_comissao, 1)                     AS taxa_comissao_pct,
    count(DISTINCT f.numero_pedido)                       AS pedidos,
    round(sum(f.receita_total), 2)                        AS receita,
    round(sum(f.receita_total) / count(DISTINCT f.numero_pedido), 2) AS ticket_medio,
    round(avg(f.desconto_pct), 1)                         AS desconto_medio,
    round(sum(f.custo_comissao), 2)                       AS comissao_paga,
    round(sum(f.margem_contribuicao), 2)                  AS margem,
    round(100.0 * sum(f.margem_contribuicao)
               / nullif(sum(f.receita_total), 0), 1)      AS margem_pct,
    rank() OVER (ORDER BY sum(f.receita_total) DESC)      AS posicao_receita,
    rank() OVER (ORDER BY sum(f.margem_contribuicao)
                        / nullif(sum(f.receita_total), 0) DESC) AS posicao_margem
FROM fct_vendas f
JOIN dim_vendedor v ON v.sk_vendedor = f.sk_vendedor
WHERE f.custo_confiavel
GROUP BY ALL
ORDER BY margem DESC;

-- =====================================================================
-- 10. Painel unico para exportacao ao Looker Studio
-- =====================================================================
CREATE OR REPLACE VIEW painel AS
SELECT
    t.data,
    t.ano_mes,
    f.numero_pedido,
    c.razao_social                AS cliente,
    c.segmento,
    c.regiao,
    v.nome_vendedor               AS vendedor,
    p.descricao                   AS produto,
    p.categoria,
    f.tipo_operacao,
    f.quantidade,
    f.desconto_pct,
    f.receita_total,
    f.custo_produto,
    f.custo_entrega,
    f.custo_comissao,
    f.frete_subsidiado,
    f.margem_contribuicao
FROM fct_vendas f
JOIN dim_tempo    t ON t.sk_tempo    = f.sk_tempo
JOIN dim_produto  p ON p.sk_produto  = f.sk_produto
JOIN dim_vendedor v ON v.sk_vendedor = f.sk_vendedor
JOIN dim_cliente  c ON c.sk_cliente  = f.sk_cliente
WHERE f.custo_confiavel;
