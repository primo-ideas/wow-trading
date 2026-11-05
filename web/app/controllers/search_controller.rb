class SearchController < ApplicationController
  # The search box asks for `fragment` to fill its suggestions. Without script, the
  # same results are a page of their own.
  def show
    @search = ItemSearch.new(params[:q], search_markets, limit: params[:fragment] ? ItemSearch::LIMIT : 50)
    render partial: "search/results", locals: { search: @search } if params[:fragment]
  end
end
