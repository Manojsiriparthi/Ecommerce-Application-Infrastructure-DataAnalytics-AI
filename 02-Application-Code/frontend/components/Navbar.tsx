'use client';

import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';

type User = {
  id: string;
  name: string;
  email: string;
  phone: string;
};

export default function Navbar() {
  const pathname = usePathname();
  const router = useRouter();

  const [user, setUser] = useState<User | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    function loadUser() {
      try {
        const storedUser = localStorage.getItem('user');

        if (storedUser) {
          setUser(JSON.parse(storedUser));
        } else {
          setUser(null);
        }
      } catch {
        setUser(null);
      }
    }

    loadUser();

    window.addEventListener('storage', loadUser);

    return () => {
      window.removeEventListener('storage', loadUser);
    };
  }, []);

  function isActive(path: string) {
    if (path === '/') {
      return pathname === '/';
    }

    return pathname.startsWith(path);
  }

  function logout() {
    localStorage.removeItem('token');
    localStorage.removeItem('user');

    setUser(null);
    setMenuOpen(false);

    router.push('/login');
  }

  return (
    <>
      {/* Top announcement bar */}
      <div className="announcement">
        <div>🚚 Free Delivery on orders above ₹499</div>
        <span>•</span>
        <div>↩️ Easy Returns</div>
        <span>•</span>
        <div>🔒 Secure Payments</div>

        <div className="announcement-right">
          <span>📦 Orders</span>
          <span>❓ Help</span>
        </div>
      </div>

      {/* Main header */}
      <header className="main-header">

        {/* Brand */}
        <Link href="/" className="brand">
          <div className="brand-icon">🛒</div>

          <div>
            <div className="brand-name">
              E-<span>Commerce</span>
            </div>

            <div className="brand-tagline">
              Shop More • Live Better
            </div>
          </div>
        </Link>

        {/* Search */}
        <div className="search-box">
          <input
            type="text"
            placeholder="Search for products, brands and more..."
          />

          <button type="button" aria-label="Search">
            🔍
          </button>
        </div>

        {/* Header actions */}
        <div className="header-actions">

          <Link href="/cart" className="header-action">
            <span className="header-action-icon">🛒</span>
            <span>Cart</span>
          </Link>

          {user ? (
            <div className="user-area">

              <button
                type="button"
                className="user-button"
                onClick={() => setMenuOpen(!menuOpen)}
              >
                <span className="user-avatar">
                  {user.name?.charAt(0)?.toUpperCase() || 'U'}
                </span>

                <span className="user-name">
                  {user.name}
                </span>

                <span className="user-arrow">
                  {menuOpen ? '▲' : '▼'}
                </span>
              </button>

              {menuOpen && (
                <div className="user-menu">

                  <div className="user-menu-header">
                    <span className="user-avatar large">
                      {user.name?.charAt(0)?.toUpperCase() || 'U'}
                    </span>

                    <div>
                      <strong>{user.name}</strong>
                      <small>{user.email}</small>
                    </div>
                  </div>

                  <div className="user-menu-divider" />

                  <Link
                    href="/account"
                    onClick={() => setMenuOpen(false)}
                  >
                    👤 My Account
                  </Link>

                  <Link
                    href="/orders"
                    onClick={() => setMenuOpen(false)}
                  >
                    📦 My Orders
                  </Link>

                  <Link
                    href="/cart"
                    onClick={() => setMenuOpen(false)}
                  >
                    🛒 My Cart
                  </Link>

                  <div className="user-menu-divider" />

                  <button
                    type="button"
                    className="logout-button"
                    onClick={logout}
                  >
                    🚪 Logout
                  </button>

                </div>
              )}
            </div>
          ) : (
            <Link href="/login" className="login-button">
              🔐 Login
            </Link>
          )}

        </div>
      </header>

      {/* Navigation categories */}
      <nav className="category-nav">

        <Link
          href="/"
          className={isActive('/') ? 'category-link active' : 'category-link'}
        >
          <span>🏠</span>
          Home
        </Link>

        <Link
          href="/men"
          className={isActive('/men') ? 'category-link active' : 'category-link'}
        >
          <span>👕</span>
          Men
        </Link>

        <Link
          href="/women"
          className={isActive('/women') ? 'category-link active' : 'category-link'}
        >
          <span>👗</span>
          Women
        </Link>

        <Link
          href="/cart"
          className={isActive('/cart') ? 'category-link active' : 'category-link'}
        >
          <span>🛒</span>
          Cart
        </Link>

        <Link
          href="/orders"
          className={isActive('/orders') ? 'category-link active' : 'category-link'}
        >
          <span>📦</span>
          Orders
        </Link>

        <Link
          href="/account"
          className={isActive('/account') ? 'category-link active' : 'category-link'}
        >
          <span>👤</span>
          Account
        </Link>

        <Link
          href="/checkout"
          className={isActive('/checkout') ? 'category-link active' : 'category-link'}
        >
          <span>💳</span>
          Checkout
        </Link>

      </nav>
    </>
  );
}
