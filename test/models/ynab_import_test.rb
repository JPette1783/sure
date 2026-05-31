require "test_helper"

class YnabImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "YnabImport")

    YnabImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "generated rows preserve stable source row numbers" do
    import = @family.imports.create!(
      type: "YnabImport",
      raw_file_str: file_fixture("imports/ynab.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal (1..10).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
  end

  test "merges outflow and inflow columns into a single signed amount" do
    import = @family.imports.create!(
      type: "YnabImport",
      raw_file_str: file_fixture("imports/ynab.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv
    rows = import.rows.order(:source_row_number)

    # First row is an outflow ($78.32) -> negative stored amount
    assert_equal BigDecimal("-78.32"), rows.first.amount.to_d
    # Paycheck row is an inflow ($2,500.00) -> positive stored amount
    assert_equal BigDecimal("2500"), rows.find { |r| r.name == "ACME Corp" }.amount.to_d
  end

  test "signed amount strips currency symbols and thousands separators" do
    import = @family.imports.new(type: "YnabImport", number_format: "1,234.56")

    outflow_row = { "Outflow" => "$1,500.00", "Inflow" => "$0.00" }
    inflow_row  = { "Outflow" => "$0.00", "Inflow" => "$2,500.00" }

    assert_equal BigDecimal("-1500"), import.signed_csv_amount(outflow_row)
    assert_equal BigDecimal("2500"), import.signed_csv_amount(inflow_row)
  end

  test "outflow becomes an expense and inflow becomes income after signage convention" do
    import = @family.imports.create!(
      type: "YnabImport",
      raw_file_str: file_fixture("imports/ynab.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv
    rows = import.rows.order(:source_row_number)

    # In Sure, positive entry amounts are outflows (expenses)
    assert_operator rows.first.signed_amount, :>, 0, "outflow should be a positive (expense) entry amount"
    assert_operator rows.find { |r| r.name == "ACME Corp" }.signed_amount, :<, 0, "inflow should be a negative (income) entry amount"
  end
end
