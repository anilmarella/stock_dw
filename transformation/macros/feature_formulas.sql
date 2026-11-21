{#
    Formula building blocks for features. Each returns a SQL expression over window `w`
    (one security, ordered by day). Empty until there are enough days.
#}

{# Return from `days` rows back to `skip` rows back, from a running index column. #}
{% macro period_return(col, days, skip=0) -%}
    {%- if skip -%}
        LAG({{ col }}, {{ skip }}) OVER w / LAG({{ col }}, {{ days }}) OVER w - 1
    {%- else -%}
        {{ col }} / LAG({{ col }}, {{ days }}) OVER w - 1
    {%- endif -%}
{%- endmacro %}


{% macro full_window(col, days) -%}
    COUNT({{ col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW) = {{ days }}
{%- endmacro %}


{# Annualised volatility of daily returns. #}
{% macro rolling_vol(col, days) -%}
    CASE WHEN {{ full_window(col, days) }}
        THEN STDDEV_SAMP({{ col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW) * SQRT(252)
    END
{%- endmacro %}


{# How much `col` moves when `market_col` moves by 1. #}
{% macro rolling_beta(col, market_col, days) -%}
    CASE WHEN {{ full_window(col ~ ' * ' ~ market_col, days) }}
        THEN REGR_SLOPE({{ col }}, {{ market_col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW)
    END
{%- endmacro %}


{# Drop from the highest value in the window. #}
{% macro drawdown(col, days) -%}
    CASE WHEN {{ full_window(col, days) }}
        THEN {{ col }} / MAX({{ col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW) - 1
    END
{%- endmacro %}


{% macro rolling_avg(col, days) -%}
    CASE WHEN {{ full_window(col, days) }}
        THEN AVG({{ col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW)
    END
{%- endmacro %}
