# What a player would call one thing on sale: an item, or a caged pet. Every caged
# pet is the same item, so its name and icon come from its species.
class Product
  PET_PREFIX = "pet:".freeze

  attr_reader :item, :variant

  def initialize(item, variant)
    @item = item
    @variant = variant
  end

  def pet? = variant.start_with?(PET_PREFIX)

  # As in `listed_products`: gear adds up into one product, each caged pet is its own.
  def series = pet? ? variant : ""

  def name = pet&.name.presence || item.display_name

  def icon_url = pet&.icon_url.presence || item.icon_url

  def quality = item.quality

  def wowhead_url
    return "https://www.wowhead.com/battle-pet/#{species_id}" if pet?

    "https://www.wowhead.com/item=#{item.id}"
  end

  private

  def species_id = variant.delete_prefix(PET_PREFIX).to_i

  def pet
    return @pet if defined?(@pet)

    @pet = pet? ? Pet.find_by(species_id: species_id) : nil
  end
end
