'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { API, apiFetch } from '../../lib/api';

type CartItem = {
  id: string;
  productId: string;
  quantity: number;
  unitPrice: number | string;
};

type Product = {
  id: string;
  name: string;
  description: string;
  category: string;
  gender: string;
  price: number | string;
  stock: number;
  imageUrl?: string | null;
};

export default function Cart() {
  const [items, setItems] = useState<CartItem[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  async function loadCart() {
    try {
      setLoading(true);
      setError('');

      const cartResponse = await apiFetch(`${API.cart}/api/cart`);

      const cartData = await cartResponse.json();

      if (!cartResponse.ok) {
        setError(cartData.message || 'Please login to view your cart');
        return;
      }

      const cartItems = cartData.items || [];

      setItems(cartItems);

      /*
       * Cart service stores productId.
       * Product service stores product details.
       *
       * We load the products and match them using productId.
       */
      try {
        const productResponse = await apiFetch(
          `${API.product}/api/products`
        );

        if (productResponse.ok) {
          const productData = await productResponse.json();

          setProducts(productData.products || []);
        }
      } catch (productError) {
        console.error('Product loading error:', productError);
      }
    } catch (err) {
      console.error('Cart loading error:', err);
      setError('Unable to load your cart');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadCart();
  }, []);

  function findProduct(productId: string) {
    return products.find((product) => product.id === productId);
  }

  function getImage(product: Product | undefined, index: number) {
    if (product?.imageUrl) {
      return product.imageUrl;
    }

    if (product?.gender === 'MEN') {
      return 'https://images.unsplash.com/photo-1617127365659-c47fa864d8bc?auto=format&fit=crop&w=700&q=80';
    }

    if (product?.gender === 'WOMEN') {
      return 'https://images.unsplash.com/photo-1496747611176-843222e1e57c?auto=format&fit=crop&w=700&q=80';
    }

    const fallbackImages = [
      'https://images.unsplash.com/photo-1441986300917-64674bd600d8?auto=format&fit=crop&w=700&q=80',
      'https://images.unsplash.com/photo-1525507119028-ed4c629a60a3?auto=format&fit=crop&w=700&q=80',
      'https://images.unsplash.com/photo-1483985988355-763728e1935b?auto=format&fit=crop&w=700&q=80',
    ];

    return fallbackImages[index % fallbackImages.length];
  }

  const total = items.reduce(
    (sum, item) =>
      sum + Number(item.unitPrice) * Number(item.quantity),
    0
  );

  const deliveryCharge = total >= 499 ? 0 : items.length > 0 ? 40 : 0;

  const grandTotal = total + deliveryCharge;

  if (loading) {
    return (
      <main className="cart-page">
        <div className="container">
          <div className="product-loading">
            <div className="loading-spinner">🛒</div>
            <p>Loading your cart...</p>
          </div>
        </div>
      </main>
    );
  }

  return (
    <main className="cart-page">
      <div className="container">

        {/* PAGE HEADER */}
        <div className="section-heading">
          <div>
            <h1>Your Cart 🛒</h1>
            <p>
              Review your selected products before checkout
            </p>
          </div>

          <Link href="/" className="view-all">
            ← Continue Shopping
          </Link>
        </div>

        {/* ERROR */}
        {error && (
          <div className="error">
            {error}
          </div>
        )}

        {/* EMPTY CART */}
        {!error && items.length === 0 && (
          <div className="empty-products">
            <div>🛒</div>

            <h3>Your cart is empty</h3>

            <p>
              Looks like you haven't added anything to your cart yet.
            </p>

            <Link
              href="/"
              className="btn"
              style={{
                display: 'inline-block',
                marginTop: '18px',
              }}
            >
              Start Shopping
            </Link>
          </div>
        )}

        {/* CART */}
        {!error && items.length > 0 && (
          <div className="cart-layout">

            {/* LEFT SIDE */}
            <div className="cart-items">

              <div
                className="card"
                style={{
                  padding: '16px 20px',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                }}
              >
                <strong>
                  My Cart
                </strong>

                <span
                  style={{
                    color: '#64748b',
                    fontSize: '13px',
                  }}
                >
                  {items.length}{' '}
                  {items.length === 1 ? 'item' : 'items'}
                </span>
              </div>

              {items.map((item, index) => {
                const product = findProduct(item.productId);

                const price = Number(item.unitPrice);

                const itemTotal =
                  price * Number(item.quantity);

                return (
                  <article
                    className="cart-item"
                    key={item.id}
                  >

                    {/* PRODUCT IMAGE */}
                    <div className="cart-item-image">
                      <img
                        src={getImage(product, index)}
                        alt={
                          product?.name ||
                          'Shopping product'
                        }
                      />
                    </div>

                    {/* PRODUCT DETAILS */}
                    <div className="cart-item-info">

                      <h3>
                        {product?.name ||
                          'Product'}
                      </h3>

                      <p>
                        {product?.description ||
                          'Selected product from your cart'}
                      </p>

                      {product && (
                        <p>
                          {product.category} ·{' '}
                          {product.gender}
                        </p>
                      )}

                      <div className="cart-item-price">
                        ₹{price.toFixed(2)}
                      </div>

                      <p>
                        Quantity:{' '}
                        <strong>
                          {item.quantity}
                        </strong>
                      </p>

                    </div>

                    {/* ITEM TOTAL */}
                    <div
                      style={{
                        textAlign: 'right',
                      }}
                    >
                      <div
                        style={{
                          color: '#64748b',
                          fontSize: '12px',
                          marginBottom: '5px',
                        }}
                      >
                        Item Total
                      </div>

                      <strong
                        style={{
                          fontSize: '20px',
                        }}
                      >
                        ₹{itemTotal.toFixed(2)}
                      </strong>
                    </div>

                  </article>
                );
              })}
            </div>

            {/* RIGHT SIDE */}
            <aside className="order-summary">

              <h2>
                Price Details
              </h2>

              <div className="summary-row">
                <span>
                  Price (
                  {items.length}{' '}
                  {items.length === 1
                    ? 'item'
                    : 'items'}
                  )
                </span>

                <span>
                  ₹{total.toFixed(2)}
                </span>
              </div>

              <div className="summary-row">
                <span>
                  Delivery Charges
                </span>

                {deliveryCharge === 0 ? (
                  <span className="free-delivery">
                    FREE
                  </span>
                ) : (
                  <span>
                    ₹{deliveryCharge.toFixed(2)}
                  </span>
                )}
              </div>

              {deliveryCharge === 0 && (
                <div
                  style={{
                    padding: '9px 0',
                    color: '#15803d',
                    fontSize: '12px',
                    fontWeight: 800,
                  }}
                >
                  🎉 You got FREE delivery!
                </div>
              )}

              <div className="summary-total">
                <span>Total Amount</span>

                <span>
                  ₹{grandTotal.toFixed(2)}
                </span>
              </div>

              <p
                style={{
                  marginTop: '14px',
                  color: '#64748b',
                  fontSize: '12px',
                  lineHeight: 1.5,
                }}
              >
                🔒 Secure checkout · Easy returns
              </p>

              <Link
                href="/checkout"
                className="checkout-button"
                style={{
                  display: 'block',
                  textAlign: 'center',
                }}
              >
                Proceed to Checkout →
              </Link>

              <Link
                href="/"
                style={{
                  display: 'block',
                  marginTop: '14px',
                  textAlign: 'center',
                  color: '#2874f0',
                  fontSize: '13px',
                  fontWeight: 800,
                }}
              >
                Continue Shopping
              </Link>

            </aside>
          </div>
        )}

      </div>
    </main>
  );
}
