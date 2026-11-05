require "test_helper"

class ChartsTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 11, 5).in_time_zone

  def line_chart(rows, **options)
    LineChart.new(
      rows: rows,
      series: [
        LineChart::Series.new(key: :a, name: "A", css_class: "series-1"),
        LineChart::Series.new(key: :b, name: "B", css_class: "series-2")
      ],
      band: LineChart::Band.new(low_key: :low, high_key: :high, name: "Bande"),
      format_value: ->(value) { "v#{value}" },
      format_axis: ->(value) { "t#{value}" },
      format_parts: ->(value) { [ [ "p#{value}", nil ] ] },
      **options
    )
  end

  def row(time, a: 100, b: 50, low: 90, high: 110)
    { time: time, title: time.to_s, a: a, b: b, low: low, high: high }
  end

  def column_chart(values)
    ColumnChart.new(
      rows: values.map.with_index { |value, index|
        {
          value: value,
          time: T0 + index.hours,
          title: "b#{index}",
          tick: "t#{index}",
          details: [ [ "Quantité", [ [ value.to_s, nil ] ], value.to_s ] ]
        }
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

  test "what is counted has no fractional tick" do
    assert ChartFrame.ticks(0, 2, whole_numbers: true).all? { |tick| tick == tick.round }
    assert_includes ChartFrame.ticks(0, 2), 0.5
    assert column_chart([ 1, 2 ]).y_ticks.all? { |tick| tick == tick.round }
    assert line_chart([ row(T0, a: 1, b: 2, low: 1, high: 2) ], whole_numbers: true).y_ticks.all? { |tick| tick == tick.round }
  end

  test "lines span the plot from the first to the last row" do
    chart = line_chart([ row(T0), row(T0 + 1.hour), row(T0 + 2.hours) ])

    assert_equal 0.0, chart.x(T0)
    assert_equal 50.0, chart.x(T0 + 1.hour)
    assert_equal 100.0, chart.x(T0 + 2.hours)
  end

  test "greater values are higher up, inside the plot" do
    chart = line_chart([ row(T0, a: 100, b: 50), row(T0 + 1.hour, a: 200, b: 60) ])

    assert_operator chart.y(200), :<, chart.y(100)
    chart.y_ticks.each { |tick| assert_includes 0.0..100.0, chart.y(tick) }
  end

  test "a single point is drawn in the middle" do
    chart = line_chart([ row(T0) ])

    assert_equal 50.0, chart.x(T0)
    assert_match(/\AM50\.0 [\d.]+h0\z/, chart.line_path(:a))
  end

  test "end labels that would overlap keep only the first" do
    close = line_chart([ row(T0, a: 100, b: 100), row(T0 + 1.hour, a: 100, b: 100) ]).end_marks
    apart = line_chart([ row(T0, a: 1_000, b: 10), row(T0 + 1.hour, a: 1_000, b: 10) ]).end_marks

    assert_equal [ "v100", nil ], close.map { |mark| mark[:label] }
    assert_equal [ "v1000", "v10" ], apart.map { |mark| mark[:label] }
  end

  test "a band far above the lines does not flatten them, and stays within the plot" do
    chart = line_chart([ row(T0, a: 100, b: 50, low: 90, high: 10_000), row(T0 + 1.hour, a: 110, b: 60, low: 90, high: 10_000) ])

    assert_operator chart.y_ticks.max, :<=, 200
    coordinates = chart.band_path.delete("MZ").split("L").map { |pair| pair.split.last.to_f }
    assert coordinates.all? { |y| y.between?(0, 100) }, chart.band_path
  end

  test "the scale still makes room for a band close to the lines" do
    chart = line_chart([ row(T0, a: 100, b: 50, low: 40, high: 130) ])

    assert_operator chart.y_ticks.max, :>=, 130
    assert_operator chart.y_ticks.min, :<=, 40
  end

  test "the tooltip and the table give every series and the band" do
    chart = line_chart([ row(T0), row(T0 + 1.hour, a: 200) ])

    assert_equal [ "A", "B", "Bande" ], chart.table_columns
    assert_equal [ "v200", "v50", "v90 – v110" ], chart.table_rows.first.drop(1)

    point = chart.points.first
    assert_equal [ [ [ "p100", nil ] ], [ [ "p50", nil ] ], [ [ "p90", nil ], [ "–", nil ], [ "p110", nil ] ] ],
      point[:rows].map { |tooltip| tooltip[:parts] }
    assert_equal T0.to_i, point[:t]
    assert_equal 2, point[:y].size
  end

  test "the table lists the newest row first" do
    chart = line_chart([ row(T0), row(T0 + 1.hour) ])

    assert_equal((T0 + 1.hour).to_s, chart.table_rows.first.first)
  end

  test "columns stand on zero, and a bucket without a sale draws nothing" do
    chart = column_chart([ 5, 0, 10 ])

    assert_equal 0, chart.y_ticks.min
    assert_equal [ 50.0, nil, 100.0 ], chart.slots.map { |slot| slot[:height] }
    assert_equal 3, chart.points.size
    assert_equal [ 16.67, 50.0, 83.33 ], chart.points.map { |point| point[:x] }
  end

  test "all zero columns still have an axis" do
    chart = column_chart([ 0, 0 ])

    assert chart.slots.all? { |slot| slot[:height].nil? }
    assert_equal [ 0.0, 1.0 ], chart.y_ticks.minmax
  end

  test "a long series keeps a readable number of axis labels" do
    chart = column_chart(Array.new(100, 1))

    assert_operator chart.x_labels.size, :<=, ColumnChart::MAX_X_LABELS + 1
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

  test "a sparkline needs two points, and tells which way it went" do
    assert_not Sparkline.new([]).drawable?
    assert_not Sparkline.new([ 1.0 ]).drawable?
    assert Sparkline.new([ 1.0, 2.0 ]).drawable?
    assert_equal "up", Sparkline.new([ 1.0, 2.0 ]).direction
    assert_equal "down", Sparkline.new([ 2.0, 1.0 ]).direction
    assert_equal "flat", Sparkline.new([ 2.0, 1.0, 2.0 ]).direction
  end

  test "a sparkline stays in its box, even when flat" do
    [ [ 5.0, 5.0, 5.0 ], [ 1.0, 900.0, 3.0 ] ].each do |values|
      coordinates = Sparkline.new(values).line_path.delete("M").split("L").map { |pair| pair.split.map(&:to_f) }

      coordinates.each do |x, y|
        assert_includes 0.0..Sparkline::WIDTH, x
        assert_includes 0.0..Sparkline::HEIGHT, y
      end
    end
  end
end
