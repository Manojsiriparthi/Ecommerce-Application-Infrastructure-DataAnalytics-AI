'use client';

import Link from 'next/link';
import ProductList from '../components/ProductList';

const categories = [
  { name: 'Men', icon: '👔', href: '/men' },
  { name: 'Women', icon: '👗', href: '/women' },
  { name: 'Accessories', icon: '⌚', href: '/men' },
  { name: 'Footwear', icon: '👟', href: '/men' },
  { name: 'Bags', icon: '👜', href: '/women' },
  { name: 'Electronics', icon: '🎧', href: '/' },
  { name: 'Beauty', icon: '🌸', href: '/women' },
  { name: 'Home & Living', icon: '🏠', href: '/' },
];

export default function Home() {
  return (
    <main className="home-page">

      {/* Top announcement */}
      <div className="announcement">
        🎉 Free Shipping on Orders Above ₹999 &nbsp; | &nbsp;
        Easy Returns &nbsp; | &nbsp;
        Shop the Latest Trends!
      </div>

      {/* Header */}
      <header className="main-header">
        <Link href="/" className="brand">
          <div className="brand-icon">🛍️</div>
          <div>
            <div className="brand-name">
              E-<span>COMMERCE</span>
            </div>
            <div className="brand-tagline">Shop More. Live Better.</div>
          </div>
        </Link>

        <div className="search-box">
          <input
            type="text"
            placeholder="Search for products, brands and more..."
          />
          <button>⌕</button>
        </div>

        <nav className="main-nav">
          <Link href="/" className="active">Home</Link>
          <Link href="/men">Men</Link>
          <Link href="/women">Women</Link>

          <Link href="/cart" className="cart-link">
            Cart
            <span className="cart-icon">🛒</span>
          </Link>

          <Link href="/login" className="login-link">
            <span>♙</span> Login
          </Link>
        </nav>
      </header>

      {/* Hero */}
      <section className="hero">
        <div className="hero-content">
          <p className="hero-small">NEW SEASON. NEW STYLE.</p>

          <h1>
            Upgrade Your
            <br />
            <span>Lifestyle</span>
          </h1>

          <p className="hero-description">
            Discover the latest trends in fashion, accessories and more
            <br />
            at unbeatable prices.
          </p>

          <Link href="/men" className="shop-button">
            Shop Now →
          </Link>

          <div className="hero-features">
            <span>🚚 Fast Delivery</span>
            <span>🛡️ Secure Payments</span>
            <span>↻ Easy Returns</span>
          </div>
        </div>

        <div className="hero-fashion">
          <div className="fashion-circle">NEW</div>
          <div className="fashion-model">
            👨🏻‍🦱 &nbsp; 👩🏻‍🦰
          </div>
          <div className="fashion-text">
            Good
            <br />
            Fashion
            <br />
            Good Mood
          </div>
        </div>

        <div className="hero-dots">
          <span className="selected"></span>
          <span></span>
          <span></span>
        </div>
      </section>

      {/* Categories */}
      <section className="categories-section">
        <div className="categories">
          {categories.map((category) => (
            <Link
              href={category.href}
              className="category-item"
              key={category.name}
            >
              <div className="category-icon">
                {category.icon}
              </div>

              <span>{category.name}</span>
            </Link>
          ))}
        </div>
      </section>

      {/* Featured Products */}
      <section className="featured-section">
        <div className="section-heading">
          <div>
            <h2>Featured Products</h2>
            <p>Best picks for you</p>
          </div>

          <Link href="/men" className="view-all">
            View All →
          </Link>
        </div>

        <div className="products-wrapper">
          <ProductList />
        </div>
      </section>

      {/* Benefits */}
      <section className="benefits">
        <div>
          <span>🚚</span>
          <div>
            <strong>Fast Delivery</strong>
            <p>Quick delivery to your doorstep</p>
          </div>
        </div>

        <div>
          <span>🔒</span>
          <div>
            <strong>Secure Shopping</strong>
            <p>Your information is protected</p>
          </div>
        </div>

        <div>
          <span>↩️</span>
          <div>
            <strong>Easy Returns</strong>
            <p>Simple and hassle-free returns</p>
          </div>
        </div>

        <div>
          <span>💬</span>
          <div>
            <strong>Customer Support</strong>
            <p>We're here whenever you need us</p>
          </div>
        </div>
      </section>

    </main>
  );
}
