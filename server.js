const express = require('express');
const os = require('os');
const path = require('path');
const { MongoClient } = require('mongodb');

// ---- Configuration comes from environment variables, never hard-coded ----
const MONGO_URL = process.env.MONGO_URL;
const PORT = process.env.PORT || 3000;

if (!MONGO_URL) {
  console.error('ERROR: MONGO_URL environment variable is not set');
  process.exit(1);
}

// Fail fast (2s) if MongoDB is unreachable, so /health responds quickly
const client = new MongoClient(MONGO_URL, { serverSelectionTimeoutMS: 2000 });
const db = client.db();                       // uses the db name inside MONGO_URL
const calculations = db.collection('calculations');

// ---- Who am I? (useful later to see load balancing across pods) ----
const podName = process.env.HOSTNAME || os.hostname();

function getPodIp() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const iface of list) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address;
    }
  }
  return '127.0.0.1';
}

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ---- Server-side validation: positive finite numbers only ----
function isPositive(x) {
  return typeof x === 'number' && Number.isFinite(x) && x > 0;
}

// ---- POST /api/emi ----
app.post('/api/emi', async (req, res) => {
  const P = Number(req.body.principal);
  const rate = Number(req.body.rate);
  const n = Number(req.body.months);

  if (!isPositive(P) || !isPositive(rate) || !isPositive(n) || !Number.isInteger(n)) {
    return res.status(400).json({ error: 'Principal, rate and months must be positive numbers (months must be a whole number).' });
  }

  const r = rate / 12 / 100;                         // monthly rate
  const factor = Math.pow(1 + r, n);
  const emi = (P * r * factor) / (factor - 1);
  const totalPayment = emi * n;
  const totalInterest = totalPayment - P;

  const round2 = (v) => Math.round(v * 100) / 100;
  const result = {
    emi: round2(emi),
    totalPayment: round2(totalPayment),
    totalInterest: round2(totalInterest),
    servedBy: podName,
    podIp: getPodIp()
  };

  try {
    await calculations.insertOne({
      principal: P,
      rate: rate,
      months: n,
      emi: result.emi,
      servedBy: podName,
      createdAt: new Date()
    });
    res.json(result);
  } catch (err) {
    console.error('DB insert failed:', err.message);
    res.status(500).json({ error: 'Could not save calculation to database.' });
  }
});

// ---- GET /api/history: last 10, newest first ----
app.get('/api/history', async (req, res) => {
  try {
    const rows = await calculations.find().sort({ createdAt: -1 }).limit(10).toArray();
    res.json(rows);
  } catch (err) {
    console.error('DB read failed:', err.message);
    res.status(500).json({ error: 'Could not read history.' });
  }
});

// ---- GET /health: 200 only if MongoDB is reachable ----
app.get('/health', async (req, res) => {
  try {
    await db.command({ ping: 1 });
    res.status(200).send('OK');
  } catch (err) {
    res.status(503).send('MongoDB unreachable');
  }
});

app.listen(PORT, () => console.log(`EMI app listening on port ${PORT}, pod=${podName}`));
