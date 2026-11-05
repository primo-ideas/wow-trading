require "test_helper"

class ProductTest < ActiveSupport::TestCase
  test "an item is named after itself" do
    item = create_item(1, name: "Linen Cloth", icon_url: "https://render.example/1.jpg")
    product = Product.new(item, "")

    assert_not product.pet?
    assert_equal "Linen Cloth", product.name
    assert_equal "https://render.example/1.jpg", product.icon_url
    assert_equal "https://www.wowhead.com/item=1", product.wowhead_url
  end

  test "gear is named after the item whatever its variant" do
    assert_equal "Test Sword", Product.new(create_item(2, name: "Test Sword"), "bonus:1,2").name
  end

  test "a caged pet is named after its species" do
    item = create_item(82800, name: "Cage", icon_url: "https://render.example/cage.jpg")
    create_pet(39, name: "Cat", icon_url: "https://render.example/39.jpg")
    product = Product.new(item, "pet:39")

    assert product.pet?
    assert_equal "Cat", product.name
    assert_equal "https://render.example/39.jpg", product.icon_url
    assert_equal "https://www.wowhead.com/battle-pet/39", product.wowhead_url
  end

  test "a species not looked up yet falls back on the cage" do
    item = create_item(82800, name: "Cage", icon_url: "https://render.example/cage.jpg")
    product = Product.new(item, "pet:999")

    assert_equal "Cage", product.name
    assert_equal "https://render.example/cage.jpg", product.icon_url
  end

  test "an item the API does not know has a placeholder name" do
    Item.insert_all!([ { id: 3 } ])

    assert_equal "Item #3", Product.new(Item.find(3), "").name
  end
end
