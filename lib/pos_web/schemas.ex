defmodule PosWeb.Schemas do
  @moduledoc """
  OpenAPI schemas. They feed the Swagger docs AND validate incoming requests,
  so the documentation cannot drift from what the API actually accepts.
  Input schemas use `struct?: false`, so validated bodies arrive as plain maps.
  """

  defmodule Error do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, example: "unknown_barcode"},
            message: %Schema{type: :string, example: "No product with barcode 000"},
            details: %Schema{type: :object, nullable: true}
          },
          required: [:code, :message]
        }
      },
      required: [:error]
    })
  end

  defmodule User do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "User",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, example: "Cashier"},
        email: %Schema{type: :string, example: "cashier@pos.test"},
        role: %Schema{type: :string, enum: ["cashier", "supervisor", "manager", "admin"]}
      },
      required: [:id, :name, :email, :role]
    })
  end

  defmodule LoginRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "LoginRequest",
        type: :object,
        properties: %{
          email: %Schema{type: :string, example: "cashier@pos.test"},
          password: %Schema{type: :string, example: "password123"}
        },
        required: [:email, :password]
      },
      struct?: false
    )
  end

  defmodule LoginResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "LoginResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            token: %Schema{type: :string, description: "JWT. Send as `Authorization: Bearer <token>`"},
            expires_in: %Schema{type: :integer, description: "Seconds until expiry", example: 43200},
            user: PosWeb.Schemas.User
          },
          required: [:token, :expires_in, :user]
        }
      },
      required: [:data]
    })
  end

  defmodule UserResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "UserResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.User},
      required: [:data]
    })
  end

  defmodule Product do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Product",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sku: %Schema{type: :string, example: "SKU0001"},
        name: %Schema{type: :string, example: "Maize Flour 2kg"},
        price_cents: %Schema{type: :integer, description: "VAT-inclusive. Per kg if weighed.", example: 19_000},
        is_weighed: %Schema{type: :boolean},
        unit: %Schema{type: :string, example: "each"},
        vat_code: %Schema{type: :string, example: "B"},
        vat_rate_bp: %Schema{type: :integer, description: "Basis points: 1600 = 16%", example: 1600},
        barcodes: %Schema{type: :array, items: %Schema{type: :string}, example: ["6161100000001"]}
      },
      required: [:id, :sku, :name, :price_cents, :is_weighed, :unit, :vat_code, :vat_rate_bp, :barcodes]
    })
  end

  defmodule ProductResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ProductResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.Product},
      required: [:data]
    })
  end

  defmodule CatalogResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CatalogResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: PosWeb.Schemas.Product}},
      required: [:data]
    })
  end

  defmodule SaleItemInput do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "SaleItemInput",
        type: :object,
        description: "Only the barcode and quantity. Prices and VAT always come from the server.",
        properties: %{
          barcode: %Schema{type: :string, example: "6161100000001"},
          quantity: %Schema{
            type: :number,
            minimum: 0.001,
            description: "Whole numbers, or decimals for weighed items (kg)",
            example: 2
          }
        },
        required: [:barcode, :quantity]
      },
      struct?: false
    )
  end

  defmodule PaymentInput do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "PaymentInput",
        type: :object,
        properties: %{
          method: %Schema{
            type: :string,
            enum: ["cash", "card", "mpesa"],
            description: "`mpesa` needs `mpesa_request_id`: a CONFIRMED request made through `POST /api/mpesa/stk` for this same sale"
          },
          amount_cents: %Schema{type: :integer, minimum: 1, description: "Amount applied to the sale, excluding change"},
          tendered_cents: %Schema{type: :integer, nullable: true, description: "Cash handed over. Defaults to the amount."},
          reference: %Schema{type: :string, nullable: true, description: "Required for card: the approval code"},
          mpesa_request_id: %Schema{type: :string, format: :uuid, nullable: true, description: "For mpesa: the confirmed STK request id"},
          mpesa_trans_id: %Schema{type: :string, nullable: true, description: "For mpesa, instead of the above: the code of a payment the customer made straight to the till or paybill"}
        },
        required: [:method, :amount_cents]
      },
      struct?: false
    )
  end

  defmodule CreateSaleRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "CreateSaleRequest",
        type: :object,
        properties: %{
          id: %Schema{
            type: :string,
            format: :uuid,
            description: "Generated by the till. Sending the same id again is safe: the original sale is returned."
          },
          device_id: %Schema{type: :string, nullable: true, example: "till-1"},
          sold_at: %Schema{
            type: :string,
            format: :"date-time",
            nullable: true,
            description: "When the sale happened on the till (earlier than now if it was queued offline)"
          },
          items: %Schema{type: :array, items: PosWeb.Schemas.SaleItemInput, minItems: 1},
          payments: %Schema{type: :array, items: PosWeb.Schemas.PaymentInput, minItems: 1}
        },
        required: [:id, :items, :payments],
        example: %{
          "id" => "5b7c8f0e-3c1d-4a53-9d0e-7a1b2c3d4e5f",
          "device_id" => "till-1",
          "items" => [%{"barcode" => "6161100000001", "quantity" => 2}],
          "payments" => [%{"method" => "cash", "amount_cents" => 38_000, "tendered_cents" => 40_000}]
        }
      },
      struct?: false
    )
  end

  defmodule SaleItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SaleItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        product_id: %Schema{type: :string, format: :uuid},
        product_name: %Schema{type: :string},
        barcode: %Schema{type: :string},
        quantity: %Schema{type: :string, description: "Decimal as a string", example: "1.500"},
        unit_price_cents: %Schema{type: :integer},
        vat_rate_bp: %Schema{type: :integer},
        vat_code: %Schema{type: :string},
        line_total_cents: %Schema{type: :integer},
        line_vat_cents: %Schema{type: :integer}
      }
    })
  end

  defmodule Payment do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Payment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        method: %Schema{type: :string, enum: ["cash", "card", "mpesa"]},
        status: %Schema{type: :string, enum: ["pending", "confirmed", "failed", "timed_out"]},
        amount_cents: %Schema{type: :integer},
        tendered_cents: %Schema{type: :integer, nullable: true},
        reference: %Schema{type: :string, nullable: true}
      }
    })
  end

  defmodule Sale do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Sale",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        receipt_no: %Schema{type: :string, example: "R5B7C8F0E"},
        status: %Schema{type: :string, enum: ["held", "completed", "voided", "refunded"]},
        cashier_id: %Schema{type: :string, format: :uuid},
        device_id: %Schema{type: :string, nullable: true},
        sold_at: %Schema{type: :string, format: :"date-time"},
        subtotal_cents: %Schema{type: :integer, description: "Sum of line totals (VAT-inclusive)"},
        discount_cents: %Schema{type: :integer},
        vat_cents: %Schema{type: :integer, description: "VAT contained in the total"},
        total_cents: %Schema{type: :integer},
        change_due_cents: %Schema{type: :integer, description: "Cash change to hand back"},
        needs_review: %Schema{type: :boolean, description: "True if stock went negative"},
        etims_status: %Schema{type: :string, enum: ["pending", "submitted", "accepted", "failed"]},
        items: %Schema{type: :array, items: PosWeb.Schemas.SaleItem},
        payments: %Schema{type: :array, items: PosWeb.Schemas.Payment}
      }
    })
  end

  defmodule SaleResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SaleResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.Sale},
      required: [:data]
    })
  end

  defmodule SalesResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SalesResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: PosWeb.Schemas.Sale}},
      required: [:data]
    })
  end

  defmodule MpesaRequestInput do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "MpesaRequestInput",
        type: :object,
        properties: %{
          sale_id: %Schema{type: :string, format: :uuid, description: "The id the till will use for POST /api/sales"},
          phone: %Schema{type: :string, example: "0712345678", description: "Any Kenyan format: 07.., 01.., +254.."},
          amount_cents: %Schema{type: :integer, minimum: 100, example: 20_000, description: "Whole shillings only: a multiple of 100"}
        },
        required: [:sale_id, :phone, :amount_cents]
      },
      struct?: false
    )
  end

  defmodule MpesaRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MpesaRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sale_id: %Schema{type: :string, format: :uuid},
        amount_cents: %Schema{type: :integer},
        phone: %Schema{type: :string, example: "254712345678"},
        status: %Schema{type: :string, enum: ["pending", "confirmed", "failed", "timed_out"]},
        receipt_number: %Schema{type: :string, nullable: true, example: "NLJ7RT61SV"},
        result_code: %Schema{type: :integer, nullable: true},
        result_desc: %Schema{type: :string, nullable: true},
        paid_at: %Schema{type: :string, format: :"date-time", nullable: true},
        claimed: %Schema{type: :boolean, description: "True once a sale has used this payment"}
      }
    })
  end

  defmodule MpesaRequestResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MpesaRequestResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.MpesaRequest},
      required: [:data]
    })
  end

  defmodule MpesaRequestsResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MpesaRequestsResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: PosWeb.Schemas.MpesaRequest}},
      required: [:data]
    })
  end

  defmodule C2BPayment do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "C2BPayment",
      type: :object,
      properties: %{
        trans_id: %Schema{type: :string, example: "RKTQDM7W6S"},
        amount_cents: %Schema{type: :integer},
        payer_name: %Schema{type: :string, nullable: true, example: "JOHN DOE"},
        paid_at: %Schema{type: :string, format: :"date-time"},
        transaction_type: %Schema{type: :string, nullable: true, example: "Buy Goods"},
        bill_ref_number: %Schema{type: :string, nullable: true},
        claimed: %Schema{type: :boolean, description: "True once a sale has used this payment"}
      }
    })
  end

  defmodule C2BPaymentResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "C2BPaymentResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.C2BPayment},
      required: [:data]
    })
  end

  defmodule OpenShiftRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "OpenShiftRequest",
        type: :object,
        properties: %{
          opening_float_cents: %Schema{type: :integer, minimum: 0, example: 500_000, description: "Cash counted into the drawer"},
          device_id: %Schema{type: :string, nullable: true, example: "till-1", description: "Which till. Defaults to till-1."}
        },
        required: [:opening_float_cents]
      },
      struct?: false
    )
  end

  defmodule CloseShiftRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "CloseShiftRequest",
        type: :object,
        properties: %{
          counted_cash_cents: %Schema{type: :integer, minimum: 0, example: 1_250_000, description: "Everything counted in the drawer, float included"}
        },
        required: [:counted_cash_cents]
      },
      struct?: false
    )
  end

  defmodule ApproveShiftRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "ApproveShiftRequest",
        type: :object,
        properties: %{note: %Schema{type: :string, nullable: true, example: "Checked the safe, agreed"}}
      },
      struct?: false
    )
  end

  defmodule ShiftReport do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ShiftReport",
      type: :object,
      description: "X or Z report. Money is integer cents. `cash.expected_cash_cents` is hidden from cashiers while the shift is open.",
      properties: %{
        shift: %Schema{type: :object},
        sales_count: %Schema{type: :integer},
        total_sales_cents: %Schema{type: :integer},
        vat_cents: %Schema{type: :integer, description: "VAT contained in the total"},
        needs_review_count: %Schema{type: :integer},
        by_payment_method: %Schema{type: :array, items: %Schema{type: :object}},
        vat_by_code: %Schema{type: :array, items: %Schema{type: :object}},
        cash: %Schema{type: :object}
      }
    })
  end

  defmodule ShiftReportResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ShiftReportResponse",
      type: :object,
      properties: %{data: PosWeb.Schemas.ShiftReport},
      required: [:data]
    })
  end

  defmodule Shift do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Shift",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        user_id: %Schema{type: :string, format: :uuid},
        device_id: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["open", "pending_approval", "closed"]},
        opening_float_cents: %Schema{type: :integer},
        opened_at: %Schema{type: :string, format: :"date-time"},
        closed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        counted_cash_cents: %Schema{type: :integer, nullable: true},
        expected_cash_cents: %Schema{type: :integer, nullable: true},
        difference_cents: %Schema{type: :integer, nullable: true, description: "Counted minus expected"},
        approved_by_id: %Schema{type: :string, format: :uuid, nullable: true},
        close_note: %Schema{type: :string, nullable: true},
        z_report: %Schema{type: :object, nullable: true}
      }
    })
  end

  defmodule ShiftResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ShiftResponse",
      type: :object,
      properties: %{data: %Schema{type: :object, nullable: true, description: "A Shift, or null when none is open"}},
      required: [:data]
    })
  end

  defmodule ShiftsResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ShiftsResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: PosWeb.Schemas.Shift}},
      required: [:data]
    })
  end

  defmodule GenericResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GenericResponse",
      type: :object,
      properties: %{data: %Schema{description: "The result: an object or a list, see the endpoint description"}},
      required: [:data]
    })
  end

  defmodule ProductInput do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "ProductInput",
        type: :object,
        properties: %{
          sku: %Schema{type: :string, example: "MZ-2KG"},
          name: %Schema{type: :string, example: "Maize Flour 2kg"},
          price_cents: %Schema{type: :integer, minimum: 0, example: 19_000, description: "VAT-inclusive; per kg if weighed"},
          cost_cents: %Schema{type: :integer, minimum: 0, example: 15_000},
          vat_code: %Schema{type: :string, example: "B", description: "Tax code A to E"},
          is_weighed: %Schema{type: :boolean},
          unit: %Schema{type: :string, example: "each"},
          reorder_level: %Schema{type: :number, minimum: 0, example: 20},
          etims_item_cls_cd: %Schema{type: :string, nullable: true, description: "KRA item classification code (10 characters) from selectItemClsList"},
          pkg_unit_cd: %Schema{type: :string, nullable: true, description: "KRA packaging unit code"},
          qty_unit_cd: %Schema{type: :string, nullable: true, description: "KRA quantity unit code"},
          category_id: %Schema{type: :string, format: :uuid, nullable: true, description: "Category supplying default KRA codes"},
          barcodes: %Schema{type: :array, items: %Schema{type: :string}, example: ["6161100000001"]}
        },
        required: [:sku, :name, :price_cents, :vat_code]
      },
      struct?: false
    )
  end

  defmodule ProductUpdate do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "ProductUpdate",
        type: :object,
        description: "Send only the fields that change",
        properties: %{
          name: %Schema{type: :string},
          price_cents: %Schema{type: :integer, minimum: 0},
          cost_cents: %Schema{type: :integer, minimum: 0},
          vat_code: %Schema{type: :string},
          is_weighed: %Schema{type: :boolean},
          unit: %Schema{type: :string},
          reorder_level: %Schema{type: :number, minimum: 0},
          etims_item_cls_cd: %Schema{type: :string, nullable: true, description: "KRA item classification code (10 characters) from selectItemClsList"},
          pkg_unit_cd: %Schema{type: :string, nullable: true, description: "KRA packaging unit code"},
          qty_unit_cd: %Schema{type: :string, nullable: true, description: "KRA quantity unit code"},
          category_id: %Schema{type: :string, format: :uuid, nullable: true, description: "Category supplying default KRA codes"},
          active: %Schema{type: :boolean}
        }
      },
      struct?: false
    )
  end

  defmodule ProductImportRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "ProductImportRequest",
        type: :object,
        properties: %{
          csv: %Schema{type: :string, description: "The whole file as text"},
          dry_run: %Schema{type: :boolean, description: "Check the file without saving anything"}
        },
        required: [:csv]
      },
      struct?: false
    )
  end

  defmodule GoodsReceiptRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "GoodsReceiptRequest",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid, description: "Generated by the client; repeating it is safe"},
          supplier_name: %Schema{type: :string, nullable: true},
          reference: %Schema{type: :string, nullable: true, description: "Supplier delivery note or invoice number"},
          note: %Schema{type: :string, nullable: true},
          items: %Schema{
            type: :array,
            minItems: 1,
            items: %Schema{
              type: :object,
              properties: %{
                barcode: %Schema{type: :string, nullable: true},
                sku: %Schema{type: :string, nullable: true},
                quantity: %Schema{type: :number, minimum: 0.001},
                unit_cost_cents: %Schema{type: :integer, minimum: 0, nullable: true}
              },
              required: [:quantity]
            }
          }
        },
        required: [:id, :items]
      },
      struct?: false
    )
  end

  defmodule AdjustmentRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "AdjustmentRequest",
        type: :object,
        properties: %{
          barcode: %Schema{type: :string, nullable: true},
          sku: %Schema{type: :string, nullable: true},
          quantity: %Schema{type: :number, description: "Wastage/expiry: the amount lost. Adjustment: + found, - lost"},
          reason: %Schema{type: :string, enum: ["adjustment", "wastage", "expiry"]},
          note: %Schema{type: :string, description: "Required"}
        },
        required: [:quantity, :reason, :note]
      },
      struct?: false
    )
  end

  defmodule CategoryInput do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "CategoryInput",
        type: :object,
        properties: %{
          name: %Schema{type: :string, example: "Dairy"},
          etims_item_cls_cd: %Schema{type: :string, nullable: true, description: "Default KRA item classification code"},
          pkg_unit_cd: %Schema{type: :string, nullable: true},
          qty_unit_cd: %Schema{type: :string, nullable: true}
        }
      },
      struct?: false
    )
  end

  defmodule VoidRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "VoidRequest",
        type: :object,
        properties: %{
          reason: %Schema{type: :string, example: "Customer changed their mind"},
          approver_email: %Schema{type: :string, nullable: true, description: "Supervisor or above. Not needed if you are one."},
          approver_password: %Schema{type: :string, nullable: true}
        },
        required: [:reason]
      },
      struct?: false
    )
  end

  defmodule ReturnRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(
      %{
        title: "ReturnRequest",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid, description: "Generated by the till; repeating it never refunds twice"},
          reason: %Schema{type: :string, example: "Damaged"},
          refund_method: %Schema{type: :string, enum: ["cash", "other"], description: "cash comes out of your drawer; other is refunded outside the system"},
          items: %Schema{
            type: :array,
            minItems: 1,
            items: %Schema{
              type: :object,
              properties: %{barcode: %Schema{type: :string}, quantity: %Schema{type: :number, minimum: 0.001}},
              required: [:barcode, :quantity]
            }
          },
          approver_email: %Schema{type: :string, nullable: true},
          approver_password: %Schema{type: :string, nullable: true}
        },
        required: [:id, :reason, :items]
      },
      struct?: false
    )
  end
end
