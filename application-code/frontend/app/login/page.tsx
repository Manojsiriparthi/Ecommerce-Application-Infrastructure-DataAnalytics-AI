'use client';

import { FormEvent, useState } from 'react';
import { useRouter } from 'next/navigation';
import { API } from '../../lib/api';
import Link from 'next/link';

export default function Login() {
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [password, setPassword] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const router = useRouter();

  async function submit(e: FormEvent) {
    e.preventDefault();

    setError('');
    setLoading(true);

    try {
      const response = await fetch(
        `${API.user}/api/users/login`,
        {
          method: 'POST',

          headers: {
            'Content-Type': 'application/json',
          },

          body: JSON.stringify({
            email,
            phone,
            password,
          }),
        }
      );

      const data = await response.json();

      if (!response.ok) {
        setError(data.message || 'Login failed');
        return;
      }

      /*
       * Save both authentication token and user information.
       *
       * Navbar reads these values and displays:
       *
       *        Manoj ▼
       */
      localStorage.setItem('token', data.token);

      localStorage.setItem(
        'user',
        JSON.stringify(data.user)
      );

      /*
       * Move to Home after successful login.
       */
      router.push('/');

    } catch (err) {
      console.error('Login error:', err);

      setError(
        'Unable to connect to the User Service. Please try again.'
      );

    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="container">

      <div
        style={{
          maxWidth: '460px',
          margin: '35px auto',
        }}
      >

        <div className="card">

          <div
            style={{
              textAlign: 'center',
              marginBottom: '25px',
            }}
          >
            <div
              style={{
                fontSize: '50px',
                marginBottom: '10px',
              }}
            >
              👤
            </div>

            <h1
              style={{
                margin: 0,
                fontSize: '30px',
              }}
            >
              Welcome Back
            </h1>

            <p
              style={{
                color: '#64748b',
                marginTop: '8px',
              }}
            >
              Login to continue shopping
            </p>
          </div>


          <form onSubmit={submit}>

            <label>
              <strong>Email</strong>
            </label>

            <input
              className="input"
              type="email"
              placeholder="Enter your email"
              value={email}
              onChange={(e) =>
                setEmail(e.target.value)
              }
              required
            />


            <label>
              <strong>Phone</strong>
            </label>

            <input
              className="input"
              type="tel"
              placeholder="Enter your phone number"
              value={phone}
              onChange={(e) =>
                setPhone(e.target.value)
              }
              required
            />


            <label>
              <strong>Password</strong>
            </label>

            <input
              className="input"
              type="password"
              placeholder="Enter your password"
              value={password}
              onChange={(e) =>
                setPassword(e.target.value)
              }
              required
            />


            {error && (
              <p className="error">
                {error}
              </p>
            )}


            <button
              className="btn"
              type="submit"
              disabled={loading}
              style={{
                width: '100%',
                height: '46px',
                fontSize: '15px',
              }}
            >
              {loading ? 'Logging in...' : '🔐 Login'}
            </button>

          </form>


          <div
            style={{
              textAlign: 'center',
              marginTop: '22px',
              paddingTop: '18px',
              borderTop: '1px solid #e5e7eb',
            }}
          >
            <span style={{ color: '#64748b' }}>
              Don't have an account?
            </span>{' '}

            <Link
              href="/register"
              style={{
                color: '#2874f0',
                fontWeight: 700,
              }}
            >
              Create Account
            </Link>
          </div>

        </div>

      </div>

    </main>
  );
}
