export function ResponseCurve({ low, mid, high }: { low: number; mid: number; high: number }) {
  const points = "0,62 90," + (62 - low * 2) + " 190," + (62 - mid * 2) + " 290," + (62 - high * 2) + " 380,62";
  return (
    <svg className="response-curve" viewBox="0 0 380 124" preserveAspectRatio="none" role="img" aria-label="Illustrative EQ response curve">
      <line x1="0" x2="380" y1="62" y2="62" />
      <polyline data-testid="response-curve" points={points} />
    </svg>
  );
}
