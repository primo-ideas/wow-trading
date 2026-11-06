# What the figures mean, in a line each, for the tooltips on their labels.
module TermsHelper
  TERMS = {
    sparkline: "The median price over the last 7 days.",
    median: "Half the units for sale cost less than this, half cost more. Hardly moved by a single absurd listing.",
    minimum: "The cheapest unit for sale right now.",
    change: "How much the median moved since the snapshot of about 24 hours ago.",
    for_sale: "Units listed at the latest snapshot.",
    sold: "Units whose listings disappeared before expiring, over the last 24 hours. An estimate.",
    value: "What those sales are worth at the prices they were listed at. An estimate.",
    usual: "The median of the cheapest price over the last 3 days: what the cheapest unit usually costs.",
    below_usual: "How far the cheapest unit is below its usual price.",
    resale: "Buying the cheapest unit and selling it at the usual price, after the auction house's #{(Flip::AUCTION_HOUSE_CUT * 100).round}% cut.",
    listings: "Separate listings, each of one or more units.",
    target: "The price you would buy at. The row is flagged once the cheapest unit costs that much or less.",
    best_hour: "When the most units of it sold over the last two weeks, by hour of the day, Paris time.",
    best_day: "Which day of the week the most units of it sold, on average over the last two weeks."
  }.freeze

  def term(key) = TERMS.fetch(key)
end
