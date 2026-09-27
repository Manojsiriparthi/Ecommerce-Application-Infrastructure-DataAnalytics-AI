'use client';

import { useEffect, useState } from 'react';
import { API, apiFetch } from '../lib/api';

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

export default function ProductList({
  gender,
}: {
  gender?: string;
}) {
  const [products, setProducts] = useState<Product[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    setError('');

    const url =
      `${API.product}/api/products` +
      `${gender ? `?gender=${encodeURIComponent(gender)}` : ''}`;

    apiFetch(url)
      .then(async (response) => {
        if (!response.ok) {
          throw new Error('Product service error');
        }

        return response.json();
      })
      .then((data) => {
        setProducts(data.products || []);
      })
      .catch((err) => {
        console.error('Product loading error:', err);
        setError('Unable to load products');
      })
      .finally(() => {
        setLoading(false);
      });
  }, [gender]);

  async function addToCart(product: Product) {
    const response = await apiFetch(
      `${API.cart}/api/cart/items`,
      {
        method: 'POST',

        body: JSON.stringify({
          productId: product.id,
          quantity: 1,
          unitPrice: Number(product.price),
        }),
      }
    );

    if (!response.ok) {
      alert('Please login before adding items to cart');
      return;
    }

    alert(`${product.name} added to cart`);
  }

  function getImage(product: Product) {
    /*
     * First preference:
     * use imageUrl stored in Product DB.
     */
    if (product.imageUrl) {
      return product.imageUrl;
    }

    /*
     * Temporary visual fallback.
     *
     * Once we populate imageUrl in product_db,
     * these fallback images will automatically
     * be replaced by database images.
     */
    if (product.gender === 'MEN') {
      return 'https://images.unsplash.com/photo-1617127365659-c47fa864d8bc?auto=format&fit=crop&w=700&q=80';
    }

    if (product.gender === 'WOMEN') {
      return 'https://images.unsplash.com/photo-1496747611176-843222e1e57c?auto=format&fit=crop&w=700&q=80';
    }

    return 'https://images.unsplash.com/photo-1441986300917-64674bd600d8?auto=format&fit=crop&w=700&q=80';
  }

  function getDiscount(index: number) {
    const discounts = [50, 40, 60, 30, 45, 35];

    return discounts[index % discounts.length];
  }

  function getOldPrice(price: number, discount: number) {
    return Math.round(
      price / (1 - discount / 100)
    );
  }

  if (loading) {
    return (
      <div className="product-loading">
        <div className="loading-spinner">🛍️</div>
        <p>Loading products...</p>
      </div>
    );
  }

  return (
    <div className="products-area">

      {error && (
        <div className="error">
          {error}
        </div>
      )}

      {!error && products.length === 0 && (
        <div className="empty-products">
          <div>🛍️</div>
          <h3>No products available</h3>
          <p>
            Products will appear here when they are
            available in the Product Service.
          </p>
        </div>
      )}

      {products.length > 0 && (
        <>

          {/* Product heading */}
          <div className="product-toolbar">

            <div>
              <h2>
                {gender === 'MEN'
                  ? "Men's Fashion"
                  : gender === 'WOMEN'
                    ? "Women's Fashion"
                    : 'Featured Products'}
              </h2>

              <span>
                {products.length} Products
              </span>
            </div>

            <select
              className="sort-select"
              defaultValue="popular"
            >
              <option value="popular">
                Popularity
              </option>

              <option value="low">
                Price: Low to High
              </option>

              <option value="high">
                Price: High to Low
              </option>
            </select>

          </div>


          {/* Products */}
          <div className="product-grid">

            {products.map((product, index) => {

              const price = Number(product.price);

              const discount =
                getDiscount(index);

              const oldPrice =
                getOldPrice(price, discount);

              return (
                <article
                  className="product-card"
                  key={product.id}
                >

                  {/* Discount */}
                  <div className="discount-badge">
                    {discount}% OFF
                  </div>


                  {/* Wishlist */}
                  <button
                    type="button"
                    className="wishlist-button"
                    aria-label="Add to wishlist"
                  >
                    ♡
                  </button>


                  {/* Product image */}
                  <div className="product-image-container">

                    <img
                      src={getImage(product)}
                      alt={product.name}
                      className="product-image"
                    />

                  </div>


                  {/* Product information */}
                  <div className="product-info">

                    {/* Rating */}
                    <div className="product-rating">
                      <span>⭐</span>

                      <strong>
                        {(4.2 + (index % 5) * 0.1).toFixed(1)}
                      </strong>

                      <small>
                        ({65 + index * 11})
                      </small>
                    </div>


                    {/* Name */}
                    <h3 className="product-name">
                      {product.name}
                    </h3>


                    {/* Description */}
                    <p className="product-description">
                      {product.description}
                    </p>


                    {/* Price */}
                    <div className="price-row">

                      <strong className="product-price">
                        ₹{price.toFixed(2)}
                      </strong>

                      <span className="old-price">
                        ₹{oldPrice.toLocaleString('en-IN')}
                      </span>

                    </div>


                    {/* Category */}
                    <div className="product-category">
                      {product.category} · {product.gender}
                    </div>


                    {/* Stock */}
                    <div
                      className={
                        product.stock > 0
                          ? 'stock available'
                          : 'stock unavailable'
                      }
                    >
                      {product.stock > 0
                        ? '✓ In Stock'
                        : '✕ Out of Stock'}
                    </div>


                    {/* Cart */}
                    <button
                      type="button"
                      className="add-cart-button"
                      onClick={() => addToCart(product)}
                      disabled={product.stock <= 0}
                    >
                      🛒 Add to Cart
                    </button>

                  </div>

                </article>
              );
            })}

          </div>

        </>
      )}

    </div>
  );
}
