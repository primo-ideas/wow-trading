module RealmsHelper
  def realm_home_path(realm, **options) = realm_path(realm.region, realm.slug, options)

  def item_on_realm_path(realm, item_id, **options) = realm_item_path(realm.region, realm.slug, item_id, options)

  def item_tooltip_path(realm, item_id, variant)
    realm_item_tooltip_path(realm.region, realm.slug, item_id, variant: variant.presence)
  end

  # A product's name, in its quality's color, that shows its card on hover.
  def product_link(row, realm, **options)
    link_to row.display_name, item_on_realm_path(realm, row.item_id, variant: row.variant_param),
      **options.except(:class, :data),
      class: [ "product-link", quality_class(row.quality), options[:class] ],
      data: { tooltip: item_tooltip_path(realm, row.item_id, row.variant_param), **options.fetch(:data, {}) }
  end

  # As the suggestions match as you type: without case, accents or punctuation.
  def realm_matches?(realm, query)
    simplify_name(realm.name).include?(simplify_name(query))
  end

  def realm_label(realm)
    safe_join([ tag.span(realm.region.upcase, class: "region"), " ", tag.span(realm.name, class: "realm-name") ])
  end

  private

  def simplify_name(text)
    ActiveSupport::Inflector.transliterate(text.to_s).downcase.gsub(/[^a-z0-9 ]/, "").squish
  end
end
