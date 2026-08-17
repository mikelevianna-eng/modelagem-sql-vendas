# Modelagem Dimensional e Análise em SQL

Modelo estrela construído sobre exportações brutas de ERP, com o tratamento, a modelagem e a análise inteiramente escritos em SQL.

Roda em DuckDB dentro do Google Colab. Sem instalação local, sem servidor e sem custo.

[![Abrir no Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/mikelevianna-eng/modelagem-sql-vendas/blob/main/modelagem_sql.ipynb)

> ### ⚠️ Dados fictícios
>
> A Casa Verde Distribuidora é uma empresa inventada e os dados são gerados por script. A modelagem, as regras de negócio e as consultas são reais.

---

## O que o projeto demonstra

Três arquivos CSV com formatos inconsistentes entram, e sai um modelo dimensional consultável, com as respostas para as perguntas que o dono da empresa faz.

Nenhuma linha de tratamento em Python. Conversão de tipo, deduplicação, padronização, criação de chaves substitutas e cálculo de medidas acontecem todos em SQL.

**Técnicas aplicadas:** macros, CTEs, funções de janela, agregação com `FILTER`, `GROUP BY ALL`, ranking, soma acumulada para curva ABC, `LAG` para variação mensal e média móvel.

---

## O modelo

```
                    dim_tempo
                        │
   dim_produto ─── fct_vendas ─── dim_cliente
                        │
                   dim_vendedor
```

Grão de uma linha por item de pedido. As dimensões usam chaves substitutas próprias, independentes do código do sistema de origem, e a dimensão cliente recebe um membro para pedidos órfãos, o que evita perder receita no cruzamento.

---

## O que as consultas revelam

| # | Pergunta | Resposta encontrada |
|---|---|---|
| 01 | Onde a margem se forma e onde se perde | Descartáveis opera a −8,4%, com 23% do faturamento |
| 02 | Da receita ao que sobra | R$ 973 mil de receita viram R$ 124 mil de margem |
| 03 | Como a carteira se concentra | 42 clientes concentram 80% da receita |
| 04 | Os maiores clientes são os melhores | Não. O maior rende 6,4% contra 12,7% da média |
| 05 | Até onde o desconto compensa | Acima de 10% toda venda passa a dar prejuízo |
| 06 | Quanto custa o frete grátis | R$ 63 mil no ano, metade da margem gerada |
| 07 | Como o resultado evolui | Receita cresce sem que a margem acompanhe |
| 08 | Quais produtos vendem e dão prejuízo | Concentrados na categoria de maior giro |
| 09 | Quem vende melhor | Maior receita e melhor margem coincidem, mas por pouco |

---

## Decisões técnicas

**A conversão de número respeita a posição do separador.** Havendo ponto e vírgula juntos, o ponto é milhar. Havendo só ponto, ele é decimal. Sem essa verificação, `89.90` viraria 8990.

**A conversão de data é escolhida por padrão do texto, não por tentativa em cadeia.** O `strptime` aceita `%Y` com dois dígitos, então testar o formato ISO antes da data curta faria `05-03-25` virar o ano 5. Esse defeito apareceu de verdade durante a construção e derrubou a dimensão tempo para 739 mil linhas antes de ser corrigido.

**A deduplicação tem critério de desempate explícito.** A chave `numero_pedido` mais `sequencia_item` é única no ERP, então repetição é falha de exportação. Como as cópias podem divergir em alguma coluna, o `ORDER BY` do `row_number` define qual permanece, para o resultado não depender da ordem em que o arquivo foi lido.

**Produto sem custo cadastrado não é descartado.** A receita é real e precisa aparecer no faturamento. O que fica nulo é a margem, sinalizada pela coluna `custo_confiavel`, e as consultas filtram por ela.

**A comissão usa a taxa de cada vendedor**, e não uma média única. Isso produz uma diferença pequena em relação ao projeto equivalente em Python, que aplica taxa fixa.

---

## Painel

A view `painel` entrega o grão do item com todas as dimensões resolvidas, pronta para o Looker Studio agregar e filtrar. O notebook exporta direto para uma planilha do Google.

---

## Estrutura

```
modelagem-sql-vendas/
├── modelagem_sql.ipynb   Notebook completo, do CSV bruto ao painel
├── modelo.sql            Staging, dimensões e fato
├── consultas.sql         As dez consultas analíticas
└── exemplos/
    └── painel.csv        Saída do modelo
```

---

## Limitações

O modelo não trata carga incremental nem histórico de alterações nas dimensões. Toda execução reconstrói as tabelas do zero, o que é adequado ao volume desta base e insuficiente para um ambiente produtivo.

O custo de entrega vem estimado da origem e não da fatura da transportadora.

---

## Projetos relacionados

- **Casa Verde Distribuidora** — o mesmo problema de negócio resolvido em Python, com testes automatizados
- **Diagnóstico de qualidade de dados** — a etapa anterior, que avalia se uma base está pronta para análise
