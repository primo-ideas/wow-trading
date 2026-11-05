require "test_helper"

class ReadOnlyTest < ActiveSupport::TestCase
  test "records cannot be saved" do
    market = create_market

    assert_raises(ActiveRecord::ReadOnlyRecord) { market.update!(name: "Autre") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { market.destroy! }
  end

  test "outside of tests, the database itself refuses writes" do
    configuration = Rails.application.config.database_configuration

    %w[development production].each do |environment|
      assert_equal "on", configuration.dig(environment, "variables", "default_transaction_read_only"), environment
    end
  end

  test "the accent table stays aligned, as translate() maps by position" do
    assert_equal TextSearch::ACCENTED.length, TextSearch::PLAIN.length
    assert_equal "o", TextSearch::PLAIN[TextSearch::ACCENTED.index("œ")]
    assert_equal "u", TextSearch::PLAIN[TextSearch::ACCENTED.index("ù")]
  end
end
