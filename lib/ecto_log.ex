defmodule EctoLog do
  @moduledoc "A utility which helps running a query logged by Ecto using psql or any other RDBMS client"

  defmodule ParserHelpers do
    @moduledoc false
    import NimbleParsec

    def text_surrounded_by(combinator \\ empty(), by) do
      combinator
      |> ascii_char([by])
      |> ignore()
      |> repeat_while(
        choice([
          ~s(\\#{by}) |> string() |> replace(by),
          utf8_char([])
        ]),
        {:not_surrounded_by, [by]}
      )
      |> ignore(ascii_char([by]))
      |> reduce({List, :to_string, []})
    end

    def not_surrounded_by(binary, context, _, _, by) do
      case binary do
        <<^by, _::binary>> -> {:halt, context}
        _ -> {:cont, context}
      end
    end

    def keyword(combinator \\ empty(), keyword) when is_atom(keyword) do
      binary = Atom.to_string(keyword)
      downcased = binary |> String.downcase() |> String.to_charlist()
      upcased = binary |> String.upcase() |> String.to_charlist()

      keyword =
        downcased
        |> Enum.zip(upcased)
        |> Enum.reduce(empty(), fn {letter_d, letter_u}, combinator ->
          ascii_char(combinator, [letter_d, letter_u])
        end)
        |> replace(keyword)

      combinator |> concat(keyword)
    end
  end

  defmodule Bindings do
    @moduledoc false
    import NimbleParsec
    import EctoLog.ParserHelpers

    defcombinatorp(
      :string,
      text_surrounded_by(?")
    )

    defcombinatorp(
      :boolean,
      choice([
        keyword(true),
        keyword(false)
      ])
    )

    defcombinatorp(
      :bitstring,
      empty()
      |> ignore(string("<<"))
      |> repeat(integer(min: 1, max: 3) |> ignore(optional(string(", "))))
      |> ignore(string(">>"))
      |> reduce(:reduce_to_bitstring)
    )

    defcombinatorp(
      :integer,
      empty()
      |> optional(string("-") |> replace(:negative))
      |> integer(min: 1)
      |> reduce(:reduce_to_integer)
    )

    defcombinatorp(
      :float,
      empty()
      |> optional(string("-") |> replace(:negative))
      |> integer(min: 1)
      |> ignore(string("."))
      |> integer(min: 1)
      |> reduce(:reduce_to_float)
    )

    defcombinatorp(
      :decimal,
      empty()
      |> ignore(string("#Decimal<"))
      |> choice([parsec(:float), parsec(:integer)])
      |> ignore(string(">"))
      |> reduce(:reduce_to_decimal)
    )

    defcombinatorp(
      :list,
      empty()
      |> ignore(string("["))
      |> repeat(
        [
          parsec(:boolean),
          parsec(:float),
          parsec(:bitstring),
          parsec(:integer),
          parsec(:list),
          parsec(:decimal),
          parsec(:string),
          parsec(:date),
          parsec(:utc_datetime),
          parsec(:naive_datetime)
        ]
        |> choice()
        |> ignore(optional(string(", ")))
      )
      |> ignore(string("]"))
      |> wrap()
    )

    defcombinatorp(
      :date,
      empty()
      |> ignore(string("~D["))
      |> integer(4)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string("]"))
      |> reduce(:reduce_to_date)
    )

    defcombinatorp(
      :naive_datetime,
      empty()
      |> ignore(string("~N["))
      |> integer(4)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string(" "))
      |> integer(2)
      |> ignore(string(":"))
      |> integer(2)
      |> ignore(string(":"))
      |> integer(2)
      |> optional(
        string(".")
        |> integer(min: 1)
      )
      |> ignore(string("]"))
      |> reduce(:reduce_to_naive_datetime)
    )

    defcombinatorp(
      :utc_datetime,
      empty()
      |> ignore(string("~U["))
      |> integer(4)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string("-"))
      |> integer(2)
      |> ignore(string(" "))
      |> integer(2)
      |> ignore(string(":"))
      |> integer(2)
      |> ignore(string(":"))
      |> integer(2)
      |> optional(
        string(".")
        |> ignore()
        |> integer(min: 1)
      )
      |> ignore(string("Z]"))
      |> reduce(:reduce_to_utc_datetime)
    )

    defparsecp(
      :bindings,
      " "
      |> string()
      |> ignore()
      |> parsec(:list)
      |> ignore(optional(repeat(string("\n"))))
      |> eos()
    )

    defparsec(
      :split_log,
      empty()
      |> repeat_while(utf8_char([]), {:not_bindings, []})
      |> reduce(:to_string)
      |> parsec(:bindings)
    )

    defp reduce_to_date([year, month, day]) do
      Date.new!(year, month, day)
    end

    defp reduce_to_naive_datetime([year, month, day, hours, minutes, seconds | rest]) do
      microseconds =
        case rest do
          [] -> 0
          [microseconds] -> microseconds
        end

      NaiveDateTime.new!(year, month, day, hours, minutes, seconds, microseconds)
    end

    defp reduce_to_utc_datetime([year, month, day, hours, minutes, seconds | rest]) do
      microseconds =
        case rest do
          [] -> 0
          [microseconds] -> microseconds
        end

      DateTime.from_naive!(
        NaiveDateTime.new!(year, month, day, hours, minutes, seconds, microseconds),
        "Etc/UTC"
      )
    end

    defp reduce_to_bitstring(list) do
      Enum.into(list, <<>>, &<<&1>>)
    end

    defp reduce_to_integer([:negative, number]) do
      -1 * number
    end

    defp reduce_to_integer([number]) do
      number
    end

    defp reduce_to_float([:negative, a, b]) do
      {float, ""} = Float.parse("-#{a}.#{b}")
      float
    end

    defp reduce_to_float([a, b]) do
      {float, ""} = Float.parse("#{a}.#{b}")
      float
    end

    defp reduce_to_decimal([integer]) when is_integer(integer), do: Decimal.new(integer)
    defp reduce_to_decimal([float]) when is_float(float), do: Decimal.from_float(float)

    defp not_bindings(binary, context, _, _) do
      case bindings(binary) do
        {:ok, _, _, _, _, _} -> {:halt, context}
        {:error, _, _, _, _, _} -> {:cont, context}
      end
    end
  end

  @doc ~S"""
  ## Examples

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "chat_rewards" AS c0 WHERE (c0."units" > $1) LIMIT 1 [#Decimal<0.1>]|)
      "SELECT TRUE FROM \"chat_rewards\" AS c0 WHERE (c0.\"units\" > 0.1) LIMIT 1"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."years" > $1 AND u0."years" < $2) LIMIT 1 [-0.34, 0.34]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"years\" > -0.34 AND u0.\"years\" < 0.34) LIMIT 1"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."years" > $1 AND u0."years" < $2) LIMIT 1 [-34, 34]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"years\" > -34 AND u0.\"years\" < 34) LIMIT 1"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."id" = ANY($1)) [[<<201, 244, 75, 51, 235, 107, 73, 170, 184, 17, 100, 108, 107, 182, 57, 197>>, <<46, 177, 109, 224, 217, 190, 72, 75, 173, 41, 23, 53, 191, 198, 167, 184>>]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"id\" = ANY('{c9f44b33-eb6b-49aa-b811-646c6bb639c5,2eb16de0-d9be-484b-ad29-1735bfc6a7b8}'))"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."first_name" = ANY($1)) [["hello", "world"]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"first_name\" = ANY('{hello,world}'))"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at" > $1) [~U[2020-12-11 00:00:00Z]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\" > '2020-12-11T00:00:00.000000Z')"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at" = ANY($1)) [[~U[2020-12-12 10:46:32.612871Z], ~U[2020-12-12 10:46:32.612884Z]]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\" = ANY('{2020-12-12T10:46:32.612871Z,2020-12-12T10:46:32.612884Z}'))"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at"::date > $1) [~D[2020-12-11]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\"::date > '2020-12-11')"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at"::date = ANY($1)) [[~D[2020-12-12], ~D[2020-12-01]]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\"::date = ANY('{2020-12-12,2020-12-01}'))"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at"::timestamp > $1) [~N[2020-12-11 22:30:13]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\"::timestamp > '2020-12-11T22:30:13.000000')"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."inserted_at"::timestamp = ANY($1)) [[~N[2020-12-12 10:51:02], ~N[2020-12-12 10:51:02]]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"inserted_at\"::timestamp = ANY('{2020-12-12T10:51:02.000000,2020-12-12T10:51:02.000000}'))"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."id" = $1) LIMIT 1 [<<155, 195, 79, 130, 225, 190, 65, 28, 171, 159, 59, 40, 165, 9, 160, 175>>]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"id\" = '9bc34f82-e1be-411c-ab9f-3b28a509a0af') LIMIT 1"

      iex> EctoLog.inline_bindings(~S|SELECT TRUE FROM "users" AS u0 WHERE (u0."id" IS NULL = ANY($1)) [[true, false]]|)
      "SELECT TRUE FROM \"users\" AS u0 WHERE (u0.\"id\" IS NULL = ANY('{true,false}'))"
  """
  @spec inline_bindings(String.t()) :: String.t()
  def inline_bindings(log) do
    {:ok, [query, bindings], _, _, _, _} = __MODULE__.Bindings.split_log(log)

    bindings
    |> Enum.with_index(1)
    |> Enum.reduce(query, fn {binding, index}, query ->
      String.replace(query, "$#{index}", stringify(binding, :root), global: false)
    end)
  end

  @doc """
  A helper which allows to format a query using external `sqlfmt` tool.

  ### Example
      "select $1 [true]" |> EctoLog.inline_bindings() |> EctoLog.format_query()
  """
  @spec format_query(String.t()) :: String.t()
  def format_query(query) do
    path = Briefly.create!(prefix: "EctoLog")
    File.write!(path, query)

    "sqlfmt --use-spaces --print-width=80 --tab-width=2 < #{path}"
    |> String.to_charlist()
    |> :os.cmd()
    |> to_string()
  end

  # is_atom for booleans only
  defp stringify(binding, _level)
       when is_float(binding) or is_integer(binding) or is_atom(binding),
       do: to_string(binding)

  defp stringify(%Decimal{} = binding, _level), do: to_string(binding)

  defp stringify(binding, level) when is_binary(binding) do
    string =
      cond do
        is_binary_uuid(binding) -> UUID.binary_to_string!(binding)
        true -> binding
      end

    case level do
      :root -> "'#{string}'"
      :child -> string
    end
  end

  defp stringify(binding, :root) when is_list(binding) do
    "'{" <> Enum.join(Enum.map(binding, &stringify(&1, :child)), ",") <> "}'"
  end

  defp stringify(%module{} = date, :root) when module in [Date, DateTime, NaiveDateTime] do
    "'#{stringify(date, :child)}'"
  end

  defp stringify(%Date{} = date, :child) do
    to_string(date)
  end

  defp stringify(%NaiveDateTime{} = datetime, :child) do
    NaiveDateTime.to_iso8601(datetime)
  end

  defp stringify(%DateTime{} = datetime, :child) do
    DateTime.to_iso8601(datetime)
  end

  defp is_binary_uuid(binary) when is_binary(binary) do
    is_binary(UUID.binary_to_string!(binary))
  rescue
    ArgumentError ->
      false
  end

  defp is_binary_uuid(_), do: false
end
