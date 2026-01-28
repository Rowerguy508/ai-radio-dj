/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        zinc: {
          850: '#1f1f22',
          900: '#18181b',
          950: '#09090b',
        },
      },
    },
  },
  plugins: [],
};
