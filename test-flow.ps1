# Food Delivery API - full flow test (PowerShell)
# Run:  powershell -ExecutionPolicy Bypass -File .\test-flow.ps1
$base = "http://localhost:8080"
$sfx  = Get-Random -Maximum 99999

function Call($method, $path, $body = $null, $token = $null) {
  $h = @{}
  if ($token) { $h["Authorization"] = "Bearer $token" }
  $args2 = @{ Method = $method; Uri = "$base$path"; Headers = $h }
  if ($body) { $args2["ContentType"] = "application/json"; $args2["Body"] = ($body | ConvertTo-Json -Depth 10) }
  Invoke-RestMethod @args2
}
function Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "   PASS: $text" -ForegroundColor Green }
function Fail($text)     { Write-Host "   FAIL: $text" -ForegroundColor Red; exit 1 }

try {
  Step 1 "Register restaurant, customer, driver"
  $shop = Call Post "/auth/register" @{ name="Shop"; email="shop$sfx@test.com"; password="password123"; role="restaurant" }
  $cust = Call Post "/auth/register" @{ name="Dara"; email="dara$sfx@test.com"; password="password123"; role="customer" }
  $drv  = Call Post "/auth/register" @{ name="Sok";  email="sok$sfx@test.com";  password="password123"; role="driver" }
  Ok "3 accounts created"

  Step 2 "Login (customer)"
  $login = Call Post "/auth/login" @{ email="dara$sfx@test.com"; password="password123" }
  if ($login.token) { Ok "got JWT token" } else { Fail "no token" }

  Step 3 "Restaurant creates menu"
  $rest = Call Post "/restaurants" @{ name="Num Banh Chok Shop"; lat=11.5564; lng=104.9282;
            menu=@(@{ sku="A1"; name="Num Banh Chok"; price=2.5 }) } $shop.token
  Ok "restaurant id = $($rest.id)"

  Step 4 "Customer places order (2 x 2.5 = 5.0)"
  $order = Call Post "/orders" @{ restaurantId=$rest.id; items=@(@{ sku="A1"; qty=2 }); lat=11.56; lng=104.92 } $cust.token
  if ($order.total -eq 5) { Ok "order id = $($order.id), total = $($order.total)" } else { Fail "wrong total: $($order.total)" }

  Step 5 "Create payment, then simulate provider approval"
  $pay = Call Post "/payments" @{ orderId=$order.id } $cust.token
  Ok "payment id = $($pay.paymentId)"
  Call Post "/payments/$($pay.paymentId)/simulate-paid" | Out-Null
  $o = Call Get "/orders/$($order.id)" $null $cust.token
  if ($o.status -eq "paid") { Ok "order status = paid" } else { Fail "status is $($o.status)" }

  Step 6 "Restaurant prepares, driver delivers"
  Call Patch "/orders/$($order.id)/status" $null $shop.token | Out-Null   # preparing
  Call Patch "/orders/$($order.id)/status" $null $shop.token | Out-Null   # ready
  Call Post  "/orders/$($order.id)/accept" $null $drv.token | Out-Null
  Call Patch "/orders/$($order.id)/status" $null $drv.token | Out-Null    # picked_up
  Call Patch "/orders/$($order.id)/status" $null $drv.token | Out-Null    # delivered
  $o = Call Get "/orders/$($order.id)" $null $cust.token
  if ($o.status -eq "delivered") { Ok "order status = delivered" } else { Fail "status is $($o.status)" }

  Step 7 "GPS: driver reports location, customer searches nearby"
  Call Post "/drivers/location" @{ lat=11.5570; lng=104.9290 } $drv.token | Out-Null
  $near = Call Get "/drivers/nearby?lat=11.5564&lng=104.9282&radius=3000" $null $cust.token
  if (@($near).Count -ge 1) { Ok "found $(@($near).Count) driver(s) nearby" } else { Fail "no driver found" }

  Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
  exit 1
}
