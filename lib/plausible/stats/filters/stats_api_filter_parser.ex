defmodule Plausible.Stats.Filters.StatsAPIFilterParser do
  @moduledoc false

  import Plausible.Stats.Filters.Utils

  @doc """
  This function parses the filter expression given as a string.
  This filtering format is used by the public Stats API.
  """
  def parse_filter_expression(str) do
    filters = String.split(str, ";")

    Enum.map(filters, &parse_single_filter/1)
    |> Enum.reject(fn parsed -> parsed == :error end)
    |> Enum.into(%{})
  end

  defp parse_single_filter(str) do
    case to_kv(str) do
      ["event:goal" = key, raw_value] ->
        is_negated? = String.contains?(str, "!=")
        {key, parse_goal_filter(raw_value, is_negated?)}

      [key, raw_value] ->
        is_negated? = String.contains?(str, "!=")
        is_list? = list_expression?(raw_value)
        is_wildcard? = wildcard_expression?(raw_value)

        final_value = remove_escape_chars(raw_value)

        cond do
          is_wildcard? && is_negated? -> {key, {:does_not_match, raw_value}}
          is_wildcard? -> {key, {:matches, raw_value}}
          is_list? -> {key, {:member, parse_member_list(raw_value)}}
          is_negated? -> {key, {:is_not, final_value}}
          true -> {key, {:is, final_value}}
        end
        |> reject_invalid_country_codes()

      _ ->
        :error
    end
  end

  defp reject_invalid_country_codes({"visit:country", {_, code_or_codes}} = filter) do
    code_or_codes
    |> List.wrap()
    |> Enum.reduce_while(filter, fn
      value, _ when byte_size(value) == 2 -> {:cont, filter}
      _, _ -> {:halt, :error}
    end)
  end

  defp reject_invalid_country_codes(filter), do: filter

  defp to_kv(str) do
    str
    |> String.trim()
    |> String.split(["==", "!="], trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_goal_filter(value, is_negated?) do
    is_list? = list_expression?(value)
    is_wildcard? = wildcard_expression?(value)

    value =
      if is_list? do
        parse_member_list(value)
      else
        remove_escape_chars(value)
      end
      |> wrap_goal_value()

    cond do
      is_negated? && is_list? -> {:not_member, value}
      is_negated? -> {:is_not, value}
      is_list? && is_wildcard? -> {:matches_member, value}
      is_list? -> {:member, value}
      is_wildcard? -> {:matches, value}
      true -> {:is, value}
    end
  end
end
