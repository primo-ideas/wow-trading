class Item < ApplicationRecord
  # `name` stays empty until the fetcher has looked the item up, and for good when
  # the item API does not know it.
  def display_name = name.presence || "Objet ##{id}"
end
