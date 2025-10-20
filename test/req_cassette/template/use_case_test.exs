defmodule ReqCassette.Template.UseCaseTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Plug.Conn

  @cassette_dir "test/fixtures/template_use_case"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "realistic e-commerce scenarios" do
    @tag capture_log: true
    test "looks up different product SKUs using one cassette" do
      bypass = Bypass.open()

      # Record first product lookup
      Bypass.expect_once(bypass, "GET", "/products/1234-5678", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "sku" => "1234-5678",
            "name" => "Widget",
            "price" => 29.99
          })
        )
      end)

      result1 =
        with_cassette(
          "product_lookup",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/products/1234-5678",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["sku"] == "1234-5678"
      assert result1.body["name"] == "Widget"
      assert result1.body["price"] == 29.99

      # Replay with different SKU - should NOT hit server
      result2 =
        with_cassette(
          "product_lookup",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/products/9999-8888",
              plug: plug
            )
          end
        )

      # Should have new SKU substituted
      assert result2.status == 200
      assert result2.body["sku"] == "9999-8888"
      assert result2.body["name"] == "Widget"
      assert result2.body["price"] == 29.99
    end

    @tag capture_log: true
    test "searches with different query parameters using one cassette" do
      bypass = Bypass.open()

      # Record search with one SKU
      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        # Verify query string has the SKU
        assert conn.query_string =~ "sku=1111-2222"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "query" => "1111-2222",
            "results" => [
              %{"sku" => "1111-2222", "name" => "Gadget"}
            ]
          })
        )
      end)

      result1 =
        with_cassette(
          "product_search",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/search?sku=1111-2222",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["query"] == "1111-2222"

      # Replay with different SKU in query string
      result2 =
        with_cassette(
          "product_search",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/search?sku=5555-6666",
              plug: plug
            )
          end
        )

      # Should have new SKU substituted in query and results
      assert result2.status == 200
      assert result2.body["query"] == "5555-6666"
      assert [first_result] = result2.body["results"]
      assert first_result["sku"] == "5555-6666"
      assert first_result["name"] == "Gadget"
    end

    @tag capture_log: true
    test "handles POST with JSON body templating" do
      bypass = Bypass.open()

      # Record a POST with templated SKU in body
      Bypass.expect_once(bypass, "POST", "/orders", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        {:ok, json} = Jason.decode(body)

        # Verify we got the original SKU
        assert json["items"] == [%{"sku" => "1111-2222", "qty" => 5}]

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          201,
          Jason.encode!(%{
            "order_id" => "ORD-123",
            "items" => [%{"sku" => "1111-2222", "qty" => 5}],
            "total" => 149.95
          })
        )
      end)

      result1 =
        with_cassette(
          "create_order",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"items" => [%{"sku" => "1111-2222", "qty" => 5}]},
              plug: plug
            )
          end
        )

      assert result1.status == 201
      assert result1.body["items"] == [%{"sku" => "1111-2222", "qty" => 5}]

      # Replay with different SKU - should work from cassette
      result2 =
        with_cassette(
          "create_order",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"items" => [%{"sku" => "9999-8888", "qty" => 5}]},
              plug: plug
            )
          end
        )

      # Should have new SKU substituted everywhere
      assert result2.status == 201
      assert result2.body["items"] == [%{"sku" => "9999-8888", "qty" => 5}]
      assert result2.body["total"] == 149.95
    end
  end

  describe "user management scenarios" do
    @tag capture_log: true
    test "CRUD operations with templated email addresses" do
      bypass = Bypass.open()

      # Record user creation with one email
      Bypass.expect_once(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        {:ok, json} = Jason.decode(body)

        assert json["email"] == "alice@example.com"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          201,
          Jason.encode!(%{
            "id" => "user-12345",
            "email" => "alice@example.com",
            "status" => "active"
          })
        )
      end)

      result1 =
        with_cassette(
          "user_create",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [email: ~r/[\w.+-]+@[\w.-]+\.\w+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{"email" => "alice@example.com", "name" => "Alice"},
              plug: plug
            )
          end
        )

      assert result1.status == 201
      assert result1.body["email"] == "alice@example.com"

      # Replay with different email
      result2 =
        with_cassette(
          "user_create",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [email: ~r/[\w.+-]+@[\w.-]+\.\w+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/users",
              json: %{"email" => "bob@company.com", "name" => "Alice"},
              plug: plug
            )
          end
        )

      # Email should be substituted
      assert result2.status == 201
      assert result2.body["email"] == "bob@company.com"
      assert result2.body["status"] == "active"
    end

    @tag capture_log: true
    test "fetches user by ID in URI path" do
      bypass = Bypass.open()

      # Record GET request
      Bypass.expect_once(bypass, "GET", "/users/user-12345", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "user-12345",
            "email" => "alice@example.com",
            "name" => "Alice"
          })
        )
      end)

      result1 =
        with_cassette(
          "user_get",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                user_id: ~r/user-\d+/,
                email: ~r/[\w.+-]+@[\w.-]+\.\w+/
              ]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/users/user-12345", plug: plug)
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == "user-12345"

      # Replay with different user ID
      result2 =
        with_cassette(
          "user_get",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                user_id: ~r/user-\d+/,
                email: ~r/[\w.+-]+@[\w.-]+\.\w+/
              ]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/users/user-99999", plug: plug)
          end
        )

      # Both ID and email should be substituted
      assert result2.status == 200
      assert result2.body["id"] == "user-99999"
      assert result2.body["email"] == "alice@example.com"
      assert result2.body["name"] == "Alice"
    end

    @tag capture_log: true
    test "update user with email in both request and response" do
      bypass = Bypass.open()

      # Record: Update user with new email
      Bypass.expect_once(bypass, "PUT", "/users/123", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Server sees the email in request
        assert decoded["email"] == "alice@example.com"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "123",
            "email" => "alice@example.com",
            "updated_at" => "2025-01-15T10:00:00Z"
          })
        )
      end)

      result1 =
        with_cassette(
          "user_update_email",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [email: ~r/[a-z.]+@[a-z.]+\.[a-z]+/]
            ]
          ],
          fn plug ->
            Req.put!(
              "http://localhost:#{bypass.port}/users/123",
              json: %{"email" => "alice@example.com"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["email"] == "alice@example.com"

      # Replay: Update with DIFFERENT email
      # Email appears in BOTH request and response, so it should be templated
      result2 =
        with_cassette(
          "user_update_email",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [email: ~r/[a-z.]+@[a-z.]+\.[a-z]+/]
            ]
          ],
          fn plug ->
            Req.put!(
              "http://localhost:#{bypass.port}/users/123",
              json: %{"email" => "alice.new@example.com"},
              plug: plug
            )
          end
        )

      # Email in response should be substituted with new value
      assert result2.status == 200
      assert result2.body["email"] == "alice.new@example.com"
      assert result2.body["id"] == "123"
    end
  end

  describe "time-sensitive API scenarios" do
    @tag capture_log: true
    test "handles timestamps in responses" do
      bypass = Bypass.open()

      # Record request with timestamp
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "ok",
            "timestamp" => "2025-01-15T10:30:00Z",
            "expires_at" => "2025-01-15T11:30:00Z"
          })
        )
      end)

      result1 =
        with_cassette(
          "status_check",
          [
            cassette_dir: @cassette_dir,
            template: [
              # ISO 8601 timestamp pattern
              patterns: [timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          end
        )

      assert result1.status == 200
      assert result1.body["timestamp"] == "2025-01-15T10:30:00Z"

      # Replay - timestamps should be substituted
      result2 =
        with_cassette(
          "status_check",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [timestamp: ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/status", plug: plug)
          end
        )

      # Same structure, but cassette can be used with any timestamp
      assert result2.status == 200
      assert result2.body["status"] == "ok"
      assert result2.body["timestamp"] != nil
      assert result2.body["expires_at"] != nil
    end

    @tag capture_log: true
    test "handles Unix epoch timestamps" do
      bypass = Bypass.open()

      # Record with epoch timestamp
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        {:ok, json} = Jason.decode(body)

        assert json["event_time"] == "1705315800"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "received_at" => "1705315800",
            "processed_at" => "1705315805"
          })
        )
      end)

      result1 =
        with_cassette(
          "event_tracking",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Unix timestamp pattern (10 digits with word boundaries)
              patterns: [epoch: ~r/\b\d{10}\b/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/events",
              json: %{"event_time" => "1705315800", "type" => "click"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["received_at"] == "1705315800"

      # Replay with different timestamp
      result2 =
        with_cassette(
          "event_tracking",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [epoch: ~r/\b\d{10}\b/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/events",
              json: %{"event_time" => "1705399999", "type" => "click"},
              plug: plug
            )
          end
        )

      # All timestamps should be substituted
      assert result2.status == 200
      assert result2.body["received_at"] == "1705399999"
      assert result2.body["processed_at"] != nil
    end
  end

  describe "pagination scenarios" do
    @tag capture_log: true
    test "handles cursor-based pagination tokens" do
      bypass = Bypass.open()

      # Record first page request
      Bypass.expect_once(bypass, "GET", "/items", fn conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "items" => ["item1", "item2"],
            "next_cursor" => "eyJpZCI6MTIzfQ==",
            "has_more" => true
          })
        )
      end)

      result1 =
        with_cassette(
          "paginated_list",
          [
            cassette_dir: @cassette_dir,
            template: [
              # Base64 cursor pattern
              patterns: [cursor: ~r/[A-Za-z0-9+\/]+=*/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/items", plug: plug)
          end
        )

      assert result1.status == 200
      assert result1.body["next_cursor"] == "eyJpZCI6MTIzfQ=="

      # Replay - cursor should remain functional
      result2 =
        with_cassette(
          "paginated_list",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [cursor: ~r/[A-Za-z0-9+\/]+=*/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/items", plug: plug)
          end
        )

      assert result2.status == 200
      assert result2.body["has_more"] == true
      assert result2.body["next_cursor"] != nil
    end

    @tag capture_log: true
    test "handles page number in query parameters" do
      bypass = Bypass.open()

      # Record request with two page references
      Bypass.expect_once(bypass, "GET", "/products", fn conn ->
        assert conn.query_string =~ "page=page-1"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "products" => [
              %{"sku" => "1111-2222"},
              %{"sku" => "3333-4444"}
            ],
            "current_page" => "page-1",
            "next_page" => "page-2"
          })
        )
      end)

      result1 =
        with_cassette(
          "products_paginated",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                sku: ~r/\d{4}-\d{4}/,
                page: ~r/page-\d+/
              ]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/products?page=page-1&next=page-2",
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["current_page"] == "page-1"
      assert result1.body["next_page"] == "page-2"

      # Replay with different pages - must have same number of unique values
      # Recording: ["page-1", "page-2"] (2 unique)
      # Replay: ["page-5", "page-6"] (2 unique) ✅ Same count
      result2 =
        with_cassette(
          "products_paginated",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [
                sku: ~r/\d{4}-\d{4}/,
                page: ~r/page-\d+/
              ]
            ]
          ],
          fn plug ->
            Req.get!(
              "http://localhost:#{bypass.port}/products?page=page-5&next=page-6",
              plug: plug
            )
          end
        )

      # Both page numbers should be substituted
      assert result2.status == 200
      assert result2.body["current_page"] == "page-5"
      assert result2.body["next_page"] == "page-6"
      assert [first | _] = result2.body["products"]
      assert first["sku"] == "1111-2222"
    end
  end

  describe "loop pattern scenarios" do
    @tag capture_log: true
    test "multiple different values work in succession with same cassette" do
      bypass = Bypass.open()
      server_called = :counters.new(1, [])

      # First request - record
      Bypass.expect(bypass, "GET", "/product/1234-5678", fn conn ->
        :counters.add(server_called, 1, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{"sku" => "1234-5678", "name" => "Product A", "price" => 29.99})
        )
      end)

      # First iteration - records
      result1 =
        with_cassette(
          "product_lookup",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [sku: ~r/\d{4}-\d{4}/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/product/1234-5678", plug: plug)
          end
        )

      assert result1.status == 200
      assert result1.body["sku"] == "1234-5678"
      assert :counters.get(server_called, 1) == 1

      # Loop through additional SKUs - all should replay from cassette
      skus = ["5678-9012", "9012-3456"]

      for sku <- skus do
        result =
          with_cassette(
            "product_lookup",
            [
              cassette_dir: @cassette_dir,
              template: [
                patterns: [sku: ~r/\d{4}-\d{4}/]
              ]
            ],
            fn plug ->
              Req.get!("http://localhost:#{bypass.port}/product/#{sku}", plug: plug)
            end
          )

        # Each SKU should be substituted in the response
        assert result.status == 200
        assert result.body["sku"] == sku
        assert result.body["name"] == "Product A"

        # Server should not be called again - still 1
        assert :counters.get(server_called, 1) == 1
      end
    end
  end

  describe "order ID echo scenarios" do
    @tag capture_log: true
    test "order ID in request is echoed in response with substitution" do
      bypass = Bypass.open()

      # Record request with order_id in both request and response
      Bypass.expect_once(bypass, "POST", "/orders", fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        {:ok, json} = Jason.decode(body)

        assert json["order_id"] == "ORD-123"

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "order_id" => "ORD-123",
            "status" => "created",
            "confirmation" => "Order ORD-123 has been placed"
          })
        )
      end)

      result1 =
        with_cassette(
          "order_creation",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [order_id: ~r/ORD-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"order_id" => "ORD-123", "item" => "widget"},
              plug: plug
            )
          end
        )

      assert result1.status == 200
      assert result1.body["order_id"] == "ORD-123"
      assert result1.body["confirmation"] == "Order ORD-123 has been placed"

      # Replay with different order_id - should be substituted everywhere
      result2 =
        with_cassette(
          "order_creation",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [order_id: ~r/ORD-\d+/]
            ]
          ],
          fn plug ->
            Req.post!(
              "http://localhost:#{bypass.port}/orders",
              json: %{"order_id" => "ORD-999", "item" => "widget"},
              plug: plug
            )
          end
        )

      # Order ID should be substituted in all locations
      assert result2.status == 200
      assert result2.body["order_id"] == "ORD-999"
      assert result2.body["confirmation"] == "Order ORD-999 has been placed"
      assert result2.body["status"] == "created"
    end
  end

  describe "server call verification scenarios" do
    @tag capture_log: true
    test "server is not called during replay" do
      bypass = Bypass.open()
      server_called = :counters.new(1, [])

      # Record request
      Bypass.expect(bypass, "GET", "/data/12345", fn conn ->
        :counters.add(server_called, 1, 1)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{"id" => "12345", "value" => "test-data"})
        )
      end)

      # First call - records to cassette
      result1 =
        with_cassette(
          "data_fetch",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/\d{5}/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/data/12345", plug: plug)
          end
        )

      assert result1.status == 200
      assert result1.body["id"] == "12345"
      assert :counters.get(server_called, 1) == 1

      # Second call with different ID - should replay from cassette
      result2 =
        with_cassette(
          "data_fetch",
          [
            cassette_dir: @cassette_dir,
            template: [
              patterns: [id: ~r/\d{5}/]
            ]
          ],
          fn plug ->
            Req.get!("http://localhost:#{bypass.port}/data/67890", plug: plug)
          end
        )

      # Response should have substituted ID
      assert result2.status == 200
      assert result2.body["id"] == "67890"
      assert result2.body["value"] == "test-data"

      # CRITICAL: Server should NOT have been called again - counter still at 1
      assert :counters.get(server_called, 1) == 1
    end
  end
end
