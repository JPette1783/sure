class YnabImport < Import
  after_create :set_mappings

  # YNAB's register export ("Export budget" → register CSV) always emits these
  # two columns instead of a single signed amount. We merge them into one
  # signed value (inflow - outflow), so they are referenced directly rather
  # than through a configurable column mapping.
  OUTFLOW_COL_LABEL = "Outflow".freeze
  INFLOW_COL_LABEL = "Inflow".freeze

  DEFAULT_COLUMN_MAPPINGS = {
    signage_convention: "inflows_positive",
    date_col_label: "Date",
    date_format: "%m/%d/%Y",
    name_col_label: "Payee",
    account_col_label: "Account",
    category_col_label: "Category",
    tags_col_label: "Flag",
    notes_col_label: "Memo"
  }.freeze

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      {
        source_row_number: index,
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        amount: signed_csv_amount(row).to_s,
        currency: default_currency.to_s,
        name: (row[name_col_label] || default_row_name).to_s,
        category: row[category_col_label].to_s,
        tags: row[tags_col_label].to_s,
        notes: row[notes_col_label].to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      rows.each do |row|
        account = mappings.accounts.mappable_for(row.account)
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        # YNAB exports don't carry a currency column, so fall back to the
        # account's currency and then the family currency.
        effective_currency = account.currency.presence || family.currency

        entry = account.entries.build \
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          currency: effective_currency,
          notes: row.notes,
          entryable: Transaction.new(category: category, tags: tags),
          import: self

        entry.save!
      end
    end
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping, Import::AccountMapping ]
  end

  def required_column_keys
    %i[date]
  end

  def column_keys
    %i[date amount name category tags account notes]
  end

  def csv_template
    template = <<-CSV
      Account,Flag,Date,Payee,Category Group/Category,Category Group,Category,Memo,Outflow,Inflow,Cleared
      Checking,,01/01/2024,Starbucks,Everyday Expenses: Coffee,Everyday Expenses,Coffee,Morning coffee,$8.55,$0.00,Cleared
      Checking,,04/15/2024,ACME Corp,Inflow: Ready to Assign,Inflow,Ready to Assign,Bi-weekly salary,$0.00,"$2,000.00",Cleared
    CSV

    CSV.parse(template, headers: true)
  end

  # Merges YNAB's separate Outflow/Inflow columns into a single signed amount.
  # Outflows reduce the balance (negative), inflows increase it (positive),
  # matching the "inflows_positive" signage convention used by this importer.
  def signed_csv_amount(csv_row)
    outflow = sanitize_number(csv_row[OUTFLOW_COL_LABEL]).to_d
    inflow = sanitize_number(csv_row[INFLOW_COL_LABEL]).to_d

    inflow - outflow
  end

  private
    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end
end
