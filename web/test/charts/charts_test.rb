require "test_helper"

class ChartsTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 11, 5).in_time_zone

  def line_chart(rows)
    LineChart.new(
      rows: rows,
      series: [
        LineChart::Series.new(key: :a, name: "A", css_class: "series-1"),
        LineChart::Series.new(key: :b, name: "B", css_class: "series-2")
      ],
      band: LineChart::Band.new(low_key: :low, high_key: :high, name: "Bande"),
      format_value: ->(value) { "v#{value}" },
      format_axis: ->(value) { "t#{value}" }
    )
  end

  def row(time, a: 100, b: 50, low: 90, high: 110)
    { time: time, title: time.to_s, a: a, b: b, low: low, high: high }
  end

  def column_chart(values)
    ColumnChart.new(
      rows: values.map.with_index { |value, index|
        { value: value, title: "b#{index}", tick: "t#{index}", details: [ [ "Quantité", value.to_s ] ] }
      },
      format_axis: ->(value) { value.to_s }
    )
  end

  test "ticks are round and cover the range" do
    ticks = ChartFrame.ticks(1_081_722, 1_399_945)

    assert_operator ticks.first, :<=, 1_081_722
    assert_operator ticks.last, :>=, 1_399_945
    assert ticks.all? { |tick| (tick % 50_000).zero? }, ticks.inspect
  end

  test "a flat series still gets a usable range" do
    assert_operator ChartFrame.ticks(500, 500).uniq.size, :>, 1
    assert_operator ChartFrame.ticks(0, 0).uniq.size, :>, 1
  end

  test "lines span the plot from the first to the last row" do
    chart = line_chart([ row(T0), row(T0 + 1.hour), row(T0 + 2.hours) ])

    assert_equal chart.plot_left, chart.x(T0)
    assert_equal chart.plot_right, chart.x(T0 + 2.hours)
    assert_equal chart.plot_left + chart.plot_width / 2.0, chart.x(T0 + 1.hour)
  end

  test "greater values are higher up, inside the plot" do
    chart = line_chart([ row(T0, a: 100, b: 50), row(T0 + 1.hour, a: 200, b: 60) ])

    assert_operator chart.y(200), :<, chart.y(100)
    chart.y_ticks.each do |tick|
      assert_operator chart.y(tick), :>=, chart.plot_top
      assert_operator chart.y(tick), :<=, chart.plot_bottom
    end
  end

  test "a single point is drawn in the middle" do
    chart = line_chart([ row(T0) ])

    assert_equal chart.plot_left + chart.plot_width / 2.0, chart.x(T0)
    assert_match(/\AM[\d.]+ [\d.]+\z/, chart.line_path(:a))
  end

  test "end labels that would overlap keep only the first" do
    close = line_chart([ row(T0, a: 100, b: 100), row(T0 + 1.hour, a: 100, b: 100) ]).end_marks
    apart = line_chart([ row(T0, a: 1_000, b: 10), row(T0 + 1.hour, a: 1_000, b: 10) ]).end_marks

    assert_equal [ "v100", nil ], close.map { |mark| mark[:label] }
    assert_equal [ "v1000", "v10" ], apart.map { |mark| mark[:label] }
  end

  test "the tooltip and the table give every series and the band" do
    chart = line_chart([ row(T0), row(T0 + 1.hour, a: 200) ])

    assert_equal [ "A", "B", "Bande" ], chart.table_columns
    assert_equal [ "v200", "v50", "v90 – v110" ], chart.table_rows.first.drop(1)
    assert_equal [ "v100", "v50", "v90 – v110" ], chart.points.first[:rows].map { |tooltip| tooltip[:value] }
  end

  test "the table lists the newest row first" do
    chart = line_chart([ row(T0), row(T0 + 1.hour) ])

    assert_equal((T0 + 1.hour).to_s, chart.table_rows.first.first)
  end

  test "columns stand on zero and skip empty buckets" do
    chart = column_chart([ 4, 0, 10 ])

    assert_equal 0, chart.y_ticks.min
    assert_equal [ 0, 2 ], chart.columns.map { |column| column[:index] }
    chart.columns.each { |column| assert_includes column[:path], "M" }
    assert_equal 3, chart.points.size
  end

  test "columns never exceed the maximum thickness" do
    chart = column_chart([ 5 ])
    path = chart.columns.first[:path]
    left = path[/\AM([\d.]+)/, 1].to_f
    right = path[/Q([\d.]+) [\d.]+ [\d.]+ [\d.]+V[\d.]+Z\z/, 1].to_f

    assert_in_delta ColumnChart::MAX_THICKNESS, right - left, 0.2
  end

  test "a very small column stays visible" do
    chart = column_chart([ 1, 1_000_000 ])
    path = chart.columns.first[:path]
    base = path[/\AM[\d.]+ ([\d.]+)/, 1].to_f
    top = path[/Q[\d.]+ ([\d.]+) /, 1].to_f

    assert_no_match(/NaN|Infinity/, path)
    assert_operator base - top, :>=, ColumnChart::MIN_HEIGHT
  end

  test "what is counted has no fractional tick" do
    assert column_chart([ 1, 2 ]).y_ticks.all? { |tick| tick == tick.round }

    assert ChartFrame.ticks(0, 2, whole_numbers: true).all? { |tick| tick == tick.round }
    assert_includes ChartFrame.ticks(0, 2), 0.5
  end

  test "all zero columns still have an axis" do
    chart = column_chart([ 0, 0 ])

    assert_empty chart.columns
    assert_equal [ 0.0, 1.0 ], chart.y_ticks.minmax
  end

  test "the time axis stays within the period and is not crowded" do
    {
      1.day => /\A\d\dh\z/,
      7.days => /\A\d+ \S+\z/,
      90.days => /\A\d+ \S+\z/,
      700.days => /\A\d+ \S+\z/
    }.each do |span, format|
      first = T0
      ticks = TimeTicks.new(first, first + span).ticks

      assert_operator ticks.size, :>=, 2, span.inspect
      assert_operator ticks.size, :<=, 15, span.inspect
      ticks.each do |tick|
        assert_operator tick[:time], :>=, first
        assert_operator tick[:time], :<=, first + span
        assert_match format, tick[:label]
      end
    end
  end
end
