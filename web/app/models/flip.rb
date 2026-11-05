# What is left of reselling something, as the auction house keeps a share of every sale.
module Flip
  AUCTION_HOUSE_CUT = 0.05

  def self.profit(buy:, sell:) = (sell * (1 - AUCTION_HOUSE_CUT)).floor - buy
end
