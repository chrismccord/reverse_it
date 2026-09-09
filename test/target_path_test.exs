defmodule ReverseIt.TargetPathTest do
  use ExUnit.Case, async: true

  test "backend prefixes preserve trailing, repeated, and encoded path separators" do
    config = ReverseIt.init(name: UnusedFinch, backend: "http://backend/v1")

    for path <- ["/", "/objects/", "/objects/a//b/", "//object", "/a%2Fb/"] do
      assert ReverseIt.Config.build_target_path(config, path) == "/v1" <> path
    end
  end

  test "stripping remains segment-aware without normalizing the remaining resource" do
    config = ReverseIt.init(name: UnusedFinch, backend: "http://backend/v1", strip_path: "/api")
    assert ReverseIt.Config.build_target_path(config, "/api") == "/v1/"
    assert ReverseIt.Config.build_target_path(config, "/api/items/") == "/v1/items/"
    assert ReverseIt.Config.build_target_path(config, "/api//items/") == "/v1//items/"
    assert ReverseIt.Config.build_target_path(config, "/apiary/") == "/v1/apiary/"
  end
end
