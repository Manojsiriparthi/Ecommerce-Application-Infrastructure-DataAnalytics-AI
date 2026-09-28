# How It Works — End to End

**Project:** pip-project-ecommerce  
**Reading time:** 20 minutes  
**Level:** Beginner friendly — no prior AWS knowledge needed

---

## The Story We Are Following

> Manoj opens his phone, visits **ecommerce-pip.com**, logs in, finds 2 shirts, adds them to cart, pays ₹1999, and receives an SMS confirmation.

We will trace every single step of this journey — from Manoj's finger tap to the database storing his order — and explain every component along the way.

---

## Part 1 — The Big Picture (Before Any Clicks)

Before Manoj even opens the app, here is what AWS has already set up and waiting:

```
INTERNET
    │
    │  (Manoj's request travels here)
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS Cloud (us-east-1 — N. Virginia data centre)               │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  VPC — Virtual Private Cloud (our private network)       │  │
│  │  IP range: 10.1.0.0/16                                  │  │
│  │                                                          │  │
│  │  ┌─────────────────────────────────────────────────┐    │  │
│  │  │  PUBLIC SUBNETS (internet can reach here)        │    │  │
│  │  │  External ALB lives here                        │    │  │
│  │  └─────────────────────────────────────────────────┘    │  │
│  │                                                          │  │
│  │  ┌─────────────────────────────────────────────────┐    │  │
│  │  │  PRIVATE SUBNETS (internet CANNOT reach here)    │    │  │
│  │  │  Frontend + 6 backend services run here         │    │  │
│  │  └─────────────────────────────────────────────────┘    │  │
│  │                                                          │  │
│  │  ┌─────────────────────────────────────────────────┐    │  │
│  │  │  DATABASE SUBNETS (most restricted)              │    │  │
│  │  │  Aurora PostgreSQL + Redis live here            │    │  │
│  │  └─────────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

Think of it like an office building:
- **Public subnet** = reception area (anyone can enter)
- **Private subnet** = employee offices (only staff with badge)
- **Database subnet** = server room (only specific employees with special access)

---

## Part 2 — Manoj Opens the App (DNS + WAF + ALB)

### Step 1: Manoj types ecommerce-pip.com

His phone asks: "Where is ecommerce-pip.com?"

This is called a **DNS lookup** — like looking up a phone number in a directory.

```
Manoj's Phone
     │
     │  "Where is ecommerce-pip.com?"
     ▼
Amazon Route 53  (AWS's DNS service)
     │
     │  "It's at this IP address → 3.x.x.x (External ALB)"
     ▼
Manoj's Phone now knows where to send the request
```

**Route 53** is like the internet's phone book. It translates `ecommerce-pip.com` into an IP address that Manoj's phone can connect to.

---

### Step 2: Request hits AWS WAF (Security Guard)

Before the request reaches anything inside AWS, it passes through **AWS WAF** (Web Application Firewall).

**What WAF checks every single request:**

```
Manoj's request arrives at WAF
         │
         ▼
┌─────────────────────────────────┐
│  WAF checks:                    │
│  ✅ Is this a valid HTTP/HTTPS? │
│  ✅ Does it look like a browser?│
│  ✅ Is this IP rate-limited?    │
│     (max 100 requests/min)      │
│  ✅ SQL injection? → BLOCK      │
│  ✅ XSS attack? → BLOCK         │
│  ✅ Known bad bot? → BLOCK      │
└─────────────────────────────────┘
         │
         │  Manoj's normal browser request passes all checks
         ▼
    Request ALLOWED → continues to ALB
```

**Why WAF?** Without WAF, a hacker could send `'; DROP TABLE users; --` inside a form field and delete our entire user database. WAF catches this before it reaches any application code.

---

### Step 3: External ALB receives the HTTPS request

**ALB = Application Load Balancer**

This is a very important component. Let's understand it clearly.

**What is a Load Balancer?**

Imagine a McDonald's with 3 cashier counters. A manager at the door sends:
- Customer 1 → Counter 1
- Customer 2 → Counter 2  
- Customer 3 → Counter 3
- Customer 4 → Counter 1 (round robin)

The ALB is that manager. Instead of counters, it distributes requests to **pods** (running containers).

**Why do we have TWO ALBs?**

```
EXTERNAL ALB (internet-facing)          INTERNAL ALB (private)
────────────────────────────            ────────────────────────
Lives in: PUBLIC subnets               Lives in: PRIVATE subnets
Can reach: from internet               Can reach: only from inside VPC
Handles: browser → frontend            Handles: frontend → backend services
HTTPS port 443                         HTTP port 80
WAF attached to this one               No WAF (not needed, already inside VPC)
```

**Simple explanation:**
- External ALB = front door of the building (faces the street)
- Internal ALB = internal corridor (only employees use it)

**Why ALB and not NLB (Network Load Balancer)?**

| Feature | ALB (Layer 7) | NLB (Layer 4) |
|---------|-------------|-------------|
| Understands HTTP/HTTPS | ✅ Yes | ❌ No — only TCP/UDP |
| Path-based routing (/api/users) | ✅ Yes | ❌ No |
| WAF can attach | ✅ Yes | ❌ No |
| Host-based routing | ✅ Yes | ❌ No |
| Best for web apps | ✅ Yes | For gaming/IoT/raw TCP |

We use ALB because we need path-based routing (`/api/users` goes to user-service, `/api/products` goes to product-service). NLB cannot do this — it only understands IP + port, not URL paths.

---

### Step 4: External ALB forwards to Frontend Pod

The External ALB receives Manoj's HTTPS request and forwards it to one of the **frontend pods** running in the private subnet.

```
External ALB (public subnet)
         │
         │  Forward to frontend pod
         │  HTTP on port 3000
         ▼
Frontend Pod (private subnet)
  Next.js application
  Port: 3000
  Replicas: 3 (one pod in each AZ)
```

**What is a Pod?**

A pod is a running instance of our Docker container. We have 3 frontend pods (one per AZ) for high availability. If one crashes, the other 2 keep serving traffic.

**What is ip target-type?**

When the ALB forwards traffic to pods, it uses the pod's actual IP address directly (not the EC2 node's IP). This is the `target-type: ip` setting in our Ingress manifest. It's more efficient because the request goes directly to the pod, not to the node first.

---

## Part 3 — Manoj Logs In (Frontend → Internal ALB → User Service → Aurora)

### Step 5: Frontend renders the login page

The Next.js frontend serves the HTML/CSS/JS to Manoj's browser. He sees the login page.

Manoj types his email `manoj@gmail.com` and password `MyPass123!` and clicks **Login**.

---

### Step 6: Frontend calls the User Service via Internal ALB

The frontend JavaScript sends an API call:

```
POST https://ecommerce-pip.com/api/users/login
Body: { "email": "manoj@gmail.com", 
        "phone": "9999999999", 
        "password": "MyPass123!" }
```

This request goes:
```
Manoj's Browser
     │  HTTPS POST /api/users/login
     ▼
External ALB
     │  Forwards to frontend pod
     ▼
Frontend Pod (Next.js)
     │  
     │  Next.js server makes an internal API call to:
     │  http://<internal-alb-dns>/api/users/login
     ▼
Internal ALB (private subnet)
     │  
     │  Sees path: /api/users/*
     │  Routes to: user-service on port 4001
     ▼
User Service Pod (private subnet, port 4001)
```

**Why does the frontend call the Internal ALB, not the user-service directly?**

Because the frontend doesn't know which user-service pod to call. There are 2 user-service pods. The Internal ALB distributes the load between them. Also, if a pod restarts and gets a new IP address, the Internal ALB automatically updates — the frontend always calls the same ALB DNS name.

---

### Step 7: User Service verifies the password

The user-service receives the login request. Here's what happens inside the code:

```
User Service receives:
  email = "manoj@gmail.com"
  phone = "9999999999"
  password = "MyPass123!"

Step 1: Query the database
  SELECT * FROM users WHERE email = 'manoj@gmail.com'
  
Step 2: Compare password
  bcrypt.compare("MyPass123!", stored_hash)
  ← password was hashed when account was created
  ← bcrypt is one-way — cannot be reversed
  
Step 3: If match → create JWT token
  token = jwt.sign({ userId, email }, JWT_SECRET, { expiresIn: "1h" })
  
Step 4: Publish event to SNS
  SNS.publish({ type: "USER_LOGIN_SUCCESS", userId, email, phone })
  ← This triggers notification-service to send SMS
```

**What is a JWT token?**

JWT = JSON Web Token. Think of it like a wristband at a concert. Once the security person checks your ticket and puts the wristband on, you can enter any area without showing your ticket again. The wristband expires after the concert.

After login, every request from Manoj's browser includes the JWT token:
```
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJ1c2VySWQiOiIxMjMifQ...
```

---

### Step 8: Database query — how it reaches Aurora

The user-service doesn't connect to Aurora directly. It goes through **RDS Proxy**:

```
User Service Pod
     │  
     │  DATABASE_URL = proxy-endpoint:5432/user_db
     │  (from Secrets Manager via CSI driver)
     ▼
RDS Proxy (database subnet)
     │  Connection pooling — many pods share fewer DB connections
     │  If 10 pods each opened 10 connections = 100 connections
     │  With proxy: 10 pods → proxy → only 5 real DB connections
     ▼
Aurora PostgreSQL Writer Instance (database subnet)
     │  
     │  SELECT * FROM users WHERE email = ?
     │  ← parameterized query (prevents SQL injection)
     │  
     ▼
Aurora Reader Instances (for read-only queries)
```

**Why RDS Proxy?**

Aurora PostgreSQL can handle maximum ~700 connections. We have 14 pods (2 per service × 7 services). Each pod opens multiple DB connections. Without proxy, we'd hit the connection limit fast. RDS Proxy pools connections — many pods share fewer actual DB connections.

**How does the pod know the DB password?**

It never touches the password directly. The **Secrets Store CSI Driver** (running in the cluster) fetches the password from **AWS Secrets Manager** at pod startup and mounts it as a file. The Prisma client reads the `DATABASE_URL` from that file.

```
Pod starts
    │
    ▼
CSI Driver calls Secrets Manager
    │  (using IRSA — pod's IAM role)
    ▼
Secrets Manager returns:
    { "host": "proxy.xxx.rds.amazonaws.com",
      "username": "pipadmin", 
      "password": "PipEcom2026#Prod" }
    │
    ▼
CSI Driver mounts this as a file at /mnt/secrets/
    │
    ▼
Pod reads DATABASE_URL from /mnt/secrets/
    │
    ▼
Prisma connects to DB
```

The password **never appears** in:
- The pod's environment variables
- The Kubernetes YAML files
- The git repository
- The Docker image

---

## Part 4 — Manoj Browses Products (Product Service + Aurora)

### Step 9: Product listing page loads

After login, Manoj sees the product catalog. The frontend calls:

```
GET /api/products?gender=male&category=shirts
```

```
Frontend → Internal ALB → product-service:4002
                               │
                               ▼
                          RDS Proxy → Aurora Reader
                          (reads from reader, not writer)
                          SELECT * FROM products 
                            WHERE gender='male' 
                            AND category='shirts'
                               │
                               ▼
                          Returns list of 50 products
```

**Why read from Aurora Reader (not Writer)?**

Product listing is a READ operation. We have 2 reader instances that handle read traffic. The writer only handles writes (INSERT, UPDATE, DELETE). This splits the load and makes both operations faster.

---

### Step 10: Manoj adds 2 shirts to cart

Manoj clicks "Add to Cart" for Shirt A (₹999) and Shirt B (₹999).

```
POST /api/cart/items
{ "productId": "shirt-a-uuid", "quantity": 1, "unitPrice": 999.99 }

POST /api/cart/items  
{ "productId": "shirt-b-uuid", "quantity": 1, "unitPrice": 999.99 }
```

```
Frontend → Internal ALB → cart-service:4003
                               │
                               ├── Check Redis cache first
                               │   REDIS GET cart:manoj-uuid
                               │   (if cached, skip DB read)
                               │
                               ▼
                          UPSERT into cart_db
                          (write goes to Aurora Writer)
                               │
                               ▼
                          Update Redis cache
                          SET cart:manoj-uuid → { items: [...] }
                          TTL: 24 hours
```

**Why Redis for cart?**

Every time Manoj clicks any page, the frontend fetches his cart to show the cart icon count. If every page load hit Aurora, that's hundreds of DB queries per session. Redis is 100x faster than a database for simple key-value reads. Cart data is stored in Redis with a 24-hour expiry — Aurora has the permanent copy.

---

## Part 5 — Manoj Pays (Payment Service → Order Service → Notification)

### Step 11: Manoj clicks "Pay Now"

The checkout page shows total: ₹1,999.98. Manoj clicks Pay.

```
POST /api/payments
Authorization: Bearer <Manoj's JWT token>
{ "amount": 1999.98 }
```

```
Frontend → Internal ALB → payment-service:4005
                               │
                               ▼
                        1. Verify JWT token
                           jwt.verify(token, JWT_SECRET)
                           → extracts userId = "manoj-uuid"
                               │
                               ▼
                        2. Check Redis idempotency key
                           "Has this exact payment been processed already?"
                           Prevents double-charging if Manoj clicks twice
                               │
                               ▼
                        3. Create payment record in payment_db
                           INSERT INTO payments (transactionId, userId, amount, status)
                           VALUES ('TXN-uuid-123', 'manoj-uuid', 1999.98, 'SUCCESS')
                               │
                               ▼
                        4. Call user-service /internal/users/manoj-uuid
                           Gets: { name: "Manoj", email: "manoj@gmail.com", phone: "9999" }
                               │
                               ▼
                        5. Publish to SNS:
                           { type: "PAYMENT_SUCCESS", 
                             transactionId: "TXN-uuid-123",
                             amount: 1999.98,
                             name: "Manoj",
                             email: "manoj@gmail.com",
                             phone: "9999999999" }
                               │
                               ▼
                        6. Return to frontend:
                           { payment: { transactionId: "TXN-uuid-123", status: "SUCCESS" } }
```

**Why does payment call user-service?**

Payment needs Manoj's phone number to send the SMS notification. But payment-service has no phone numbers — that's user-service's job. So payment-service calls user-service's `/internal/` endpoint (protected by a shared internal key).

**What is the internal key?**

```
payment-service sends:
  GET /internal/users/manoj-uuid
  Header: x-internal-key: pip-ecom-internal-manoj-2026-svc-key-m7z

user-service checks:
  if (req.headers['x-internal-key'] !== INTERNAL_SERVICE_KEY) → 403 Forbidden
  else → return user data
```

This key is stored in SSM SecureString — never in code or YAML.

---

### Step 12: Order is created

After payment succeeds, the frontend creates the order:

```
POST /api/orders
{ "paymentTransactionId": "TXN-uuid-123",
  "totalAmount": 1999.98,
  "address": { "street": "123 MG Road", "city": "Bangalore" },
  "items": [
    { "productId": "shirt-a-uuid", "productName": "Blue Shirt", "quantity": 1, "unitPrice": 999.99 },
    { "productId": "shirt-b-uuid", "productName": "Red Shirt", "quantity": 1, "unitPrice": 999.99 }
  ] }
```

```
order-service:4004 receives request
       │
       ▼
1. Verify JWT → userId = "manoj-uuid"

2. Call payment-service to verify payment:
   GET /api/payments/TXN-uuid-123
   → Confirms status = SUCCESS, amount = 1999.98 ✅
   (cannot create order without verified payment)

3. Create order in order_db:
   INSERT INTO orders (userId, paymentTransactionId, totalAmount, ...)
   INSERT INTO order_items (orderId, productId, productName, quantity, ...)

4. Call user-service for contact details:
   GET /internal/users/manoj-uuid
   → Gets name, email, phone

5. Publish to SNS:
   { type: "ORDER_CONFIRMED",
     orderId: "order-uuid-456",
     totalAmount: 1999.98,
     name: "Manoj",
     email: "manoj@gmail.com",
     phone: "9999999999" }
```

---

### Step 13: Manoj receives SMS + Email

The SNS event travels to the notification-service:

```
SNS Topic receives: ORDER_CONFIRMED event
       │
       ▼
notification-service:4006
       │
       ├── Send SMS via SNS (direct to phone number)
       │   "Hi Manoj, your order order-uuid-456 has been confirmed."
       │
       └── Send Email via SES (Simple Email Service)
           To: manoj@gmail.com
           From: noreply@ecommerce-pip.com
           Subject: "Your Order is Confirmed"
```

Manoj sees on his phone:
- **SMS:** "Hi Manoj, your order has been confirmed. Total: ₹1,999.98"
- **Email:** Full order confirmation with item details

---

## Part 6 — Where Data Is Stored

Here is a complete map of what gets stored where:

| Data | Service | Database/Store | Table |
|------|---------|---------------|-------|
| Manoj's account | user-service | Aurora `user_db` | `users` |
| JWT token blacklist | user-service | Redis | key: `blacklist:token` |
| Product catalog | product-service | Aurora `product_db` | `products` |
| Manoj's cart | cart-service | Aurora `cart_db` + Redis | `cart_items` + cache |
| Payment record | payment-service | Aurora `payment_db` | `payments` |
| Idempotency keys | payment-service | Redis | key: `idem:payment:uuid` |
| Order + items | order-service | Aurora `order_db` | `orders`, `order_items` |
| WAF + ALB logs | AWS (automatic) | S3 bucket | `alb-logs/`, `waf-logs/` |
| Application logs | Fluent Bit | CloudWatch Logs | `/aws/eks/.../application` |

---

## Part 7 — Network Security (How Data Is Protected)

### Three Layers of Network Protection

```
Layer 1 — NACL (Network Access Control List)
  Stateless firewall on the subnet boundary
  Like a border checkpoint — checks every packet
  Database subnet NACL: only allows port 5432 (Postgres) from VPC IPs

Layer 2 — Security Group
  Stateful firewall on the instance/pod level
  Like a door lock — remembers you came in, lets you out
  Aurora Security Group: only allows port 5432 from EKS security group

Layer 3 — Application-level auth
  JWT tokens, internal keys, bcrypt password hashing
```

### Why can't a hacker reach the database directly?

```
Hacker on the internet
       │
       │  tries to connect to Aurora directly
       ▼
Internet Gateway → only routes to public subnets
       │
       │  Database subnet is NOT in a public subnet
       │  No route from internet → database subnet exists
       │
       ▼
Connection REFUSED — no route to host
```

Even if a hacker somehow got inside the VPC, the Aurora Security Group only allows connections from the EKS Security Group. A random EC2 instance cannot connect.

### VPC Flow Logs — Recording Everything

Every network connection inside the VPC is logged:

```
Who connected from: 10.0.11.5 (pod IP)
Who connected to:   10.0.21.10 (Aurora IP)
Port:               5432
Status:             ACCEPTED
Time:               2026-09-27 14:32:01 UTC
```

These logs go to CloudWatch → helps detect unusual connections.

---

## Part 8 — What Happens If Something Fails

### Pod crashes during Manoj's request

```
payment-service pod crashes mid-request
       │
       ▼
Internal ALB detects unhealthy target (health check fails)
       │
       ▼
ALB stops sending requests to crashed pod
ALB routes Manoj's request to the other healthy pod
       │
       ▼
Kubernetes (EKS) detects pod is gone
Starts a new replacement pod
       │
       ▼
New pod starts, passes health check
ALB adds it back to the rotation
Total user impact: zero (request was retried to healthy pod)
```

### Aurora writer crashes

```
Aurora writer instance crashes
       │
       ▼
RDS Proxy detects connection failure
       │
       ▼
Aurora automatically promotes Reader 1 to new Writer
(This takes 30 seconds)
       │
       ▼
RDS Proxy reconnects to new writer
Pods don't need to restart — proxy handles reconnection
Total user impact: ~30 seconds of write failures during failover
```

### Entire us-east-1 region goes down

```
us-east-1 becomes unavailable
       │
       ▼
Route53 health check detects External ALB is unhealthy
(checks every 10 seconds, fails 3 times = 30 seconds)
       │
       ▼
Route53 switches DNS to us-west-2 ALB (DR region)
(DNS TTL = 60 seconds → propagates in 60 seconds)
       │
       ▼
DR region EKS node group scales from 0 → 3 nodes (5 minutes)
Aurora DR replica promoted to writer (2 minutes)
ArgoCD deploys all pods to DR cluster (3 minutes)
       │
       ▼
Total recovery time: ~10-15 minutes
Users see errors for ~10 minutes then everything works from DR
```

---

## Summary — The Full Journey in 1 Minute

```
1. Manoj opens ecommerce-pip.com
   → Route53 translates domain to External ALB IP

2. Request passes WAF
   → OWASP check, rate limit check → passes

3. External ALB (public subnet) → Frontend pod (private subnet)
   → HTTPS 443 → Next.js server

4. Login: Frontend → Internal ALB → user-service:4001
   → Password checked with bcrypt → JWT token issued
   → Data read from Aurora (via RDS Proxy)

5. Browse products: Frontend → Internal ALB → product-service:4002
   → Read from Aurora reader instance

6. Add to cart: Frontend → Internal ALB → cart-service:4003
   → Write to Aurora + cache in Redis (fast reads)

7. Payment: Frontend → Internal ALB → payment-service:4005
   → JWT verified → payment stored in Aurora
   → SNS event published

8. Order: Frontend → Internal ALB → order-service:4004
   → Verifies payment → stores order in Aurora
   → SNS event → notification-service:4006
   → SMS via SNS + Email via SES

9. All logs → S3 (WAF logs, ALB logs)
   Application logs → CloudWatch
   22 alarms watching everything
```

---

## Quick Reference — Port Numbers

| Service | Port | Who calls it |
|---------|------|-------------|
| Frontend (Next.js) | 3000 | External ALB |
| user-service | 4001 | Internal ALB |
| product-service | 4002 | Internal ALB |
| cart-service | 4003 | Internal ALB |
| order-service | 4004 | Internal ALB |
| payment-service | 4005 | Internal ALB |
| notification-service | 4006 | Internal ALB |
| Aurora PostgreSQL | 5432 | RDS Proxy |
| Redis | 6379 | cart-service, payment-service |
| External ALB | 443 (HTTPS) | Users |
| Internal ALB | 80 (HTTP) | Frontend pods |

> **Why is Internal ALB on HTTP (not HTTPS)?**  
> TLS terminates at the External ALB. Traffic inside the VPC (private subnets) is already encrypted at the network level by AWS. Adding TLS inside the private network would waste CPU without adding meaningful security. This is standard practice.

---

*Document version: 1.0 | Project: pip-project-ecommerce*
