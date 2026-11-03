-- Decode the Bronze `amount` column back to a numeric amount.
--
-- The Debezium -> Iceberg sink writes DECIMAL(18,2) values as the raw
-- two's-complement big-endian bytes of the unscaled integer (Kafka Connect
-- Decimal / java.math.BigInteger.toByteArray), base64-encoded and stored as a
-- VARCHAR. This macro decodes it back to a numeric amount (unscaled / 100).
--
--   from_base64        -> varbinary (unscaled integer bytes, 3-4 bytes)
--   to_hex             -> uppercase hex of those bytes
--   lpad(..., 16, pad) -> sign-extend to 8 bytes (0x00 pad if positive,
--                         0xFF if negative — the first nibble >= '8' means the
--                         sign bit is set)
--   from_hex           -> 8-byte varbinary
--   from_big_endian_64 -> bigint (two's-complement)
--   / 100.0            -> apply the DECIMAL scale of 2
{% macro decode_amount(column_expr) -%}
    (
        from_big_endian_64(
            from_hex(
                lpad(
                    to_hex(from_base64({{ column_expr }})),
                    16,
                    if(substr(to_hex(from_base64({{ column_expr }})), 1, 1) >= '8', 'f', '0')
                )
            )
        )
        / 100.0
    )
{%- endmacro %}
