import './globals.css';
import Navbar from '../components/Navbar';

export const metadata = {
  title: 'E-Commerce Shopping Application',
  description: 'Shop fashion, electronics, accessories and more',
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>

        <Navbar />

        <main className="page-content">
          {children}
        </main>

      </body>
    </html>
  );
}
