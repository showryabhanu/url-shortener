const express = require('express');
const crypto = require('crypto');
const path = require('path');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  UpdateCommand,
  ScanCommand
} = require('@aws-sdk/lib-dynamodb');

// Configuration
const PORT = parseInt(process.env.PORT, 10) || 3000;
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';
const TABLE_NAME = process.env.TABLE_NAME || 'short_links';
const SHORT_DOMAIN = (process.env.SHORT_DOMAIN || 'cc7.duckdns.org').trim().toLowerCase();
const REDIRECT_STATUS = parseInt(process.env.REDIRECT_STATUS, 10) || 302;

// DynamoDB client (uses EC2 IAM Instance Profile: LabInstanceProfile / LabRole)
const ddbClient = new DynamoDBClient({ region: AWS_REGION });
const docClient = DynamoDBDocumentClient.from(ddbClient, {
  marshallOptions: { removeUndefinedValues: true }
});

const app = express();
app.set('trust proxy', true);

// Security Headers Middleware
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  next();
});

app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'public')));

// In-Memory Rate Limiting for /api/shorten (30 requests/minute per IP)
const rateLimitMap = new Map();
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const MAX_REQUESTS_PER_WINDOW = 30;

function rateLimiter(req, res, next) {
  const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() || req.socket.remoteAddress || 'unknown';
  const now = Date.now();
  const timestamps = (rateLimitMap.get(ip) || []).filter(t => now - t < RATE_LIMIT_WINDOW_MS);
  
  if (timestamps.length >= MAX_REQUESTS_PER_WINDOW) {
    return res.status(429).json({ error: 'Too many requests. Please slow down and try again shortly.' });
  }
  
  timestamps.push(now);
  rateLimitMap.set(ip, timestamps);
  next();
}

// Memory cleanup for rate limiter every 5 minutes
setInterval(() => {
  const now = Date.now();
  for (const [ip, timestamps] of rateLimitMap.entries()) {
    const valid = timestamps.filter(t => now - t < RATE_LIMIT_WINDOW_MS);
    if (valid.length === 0) {
      rateLimitMap.delete(ip);
    } else {
      rateLimitMap.set(ip, valid);
    }
  }
}, 5 * 60 * 1000);

// Base62 Alphabet & Code Generation
const BASE62 = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function generateRandomCode(length = 6) {
  const bytes = crypto.randomBytes(length);
  let result = '';
  for (let i = 0; i < length; i++) {
    result += BASE62[bytes[i] % BASE62.length];
  }
  return result;
}

// Reserved aliases that cannot be shortened
const RESERVED_ALIASES = new Set([
  'api',
  'health',
  'admin',
  'static',
  'assets',
  'favicon.ico',
  'robots.txt',
  'index.html',
  'css',
  'js'
]);

// GET /health
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    domain: SHORT_DOMAIN,
    region: AWS_REGION,
    table: TABLE_NAME,
    timestamp: new Date().toISOString()
  });
});

// GET /api/links - Most recent 50 links
app.get('/api/links', async (req, res) => {
  try {
    const command = new ScanCommand({
      TableName: TABLE_NAME,
      Limit: 50
    });
    const result = await docClient.send(command);
    const items = (result.Items || []).sort(
      (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
    );
    res.json({ links: items });
  } catch (error) {
    console.error('Failed to fetch links:', error);
    res.status(500).json({ error: 'Failed to retrieve links from database' });
  }
});

// POST /api/shorten
app.post('/api/shorten', rateLimiter, async (req, res) => {
  const { url: rawUrl, alias } = req.body || {};

  if (!rawUrl || typeof rawUrl !== 'string') {
    return res.status(400).json({ error: 'A valid URL is required.' });
  }

  const trimmedUrl = rawUrl.trim();

  // Validate URL length
  if (trimmedUrl.length > 2048) {
    return res.status(400).json({ error: 'URL exceeds maximum length of 2048 characters.' });
  }

  // Parse and validate protocol and domain
  let parsedUrl;
  try {
    parsedUrl = new URL(trimmedUrl);
  } catch (err) {
    return res.status(400).json({ error: 'Invalid URL format. Must include http:// or https://' });
  }

  const protocol = parsedUrl.protocol.toLowerCase();
  if (protocol !== 'http:' && protocol !== 'https:') {
    return res.status(400).json({
      error: 'Invalid protocol. Only http:// and https:// URLs are permitted (javascript: and data: are forbidden).'
    });
  }

  // Reject loops back to own short domain
  if (parsedUrl.hostname.toLowerCase() === SHORT_DOMAIN) {
    return res.status(400).json({ error: 'Cannot shorten links pointing to the shortener domain itself.' });
  }

  // Handle custom alias if supplied
  if (alias !== undefined && alias !== null && String(alias).trim() !== '') {
    const cleanAlias = String(alias).trim();
    if (!/^[A-Za-z0-9_-]{3,20}$/.test(cleanAlias)) {
      return res.status(400).json({
        error: 'Custom alias must be 3-20 characters and contain only letters, numbers, underscores, or hyphens.'
      });
    }

    if (RESERVED_ALIASES.has(cleanAlias.toLowerCase())) {
      return res.status(400).json({ error: `The alias "${cleanAlias}" is reserved and cannot be used.` });
    }

    const shortUrl = `https://${SHORT_DOMAIN}/${cleanAlias}`;

    // HARD LENGTH RULE
    if (shortUrl.length >= trimmedUrl.length) {
      return res.status(422).json({
        error: 'This URL is already shorter than the generated link',
        originalLength: trimmedUrl.length,
        shortLength: shortUrl.length,
        charactersSaved: trimmedUrl.length - shortUrl.length
      });
    }

    try {
      await docClient.send(
        new PutCommand({
          TableName: TABLE_NAME,
          Item: {
            code: cleanAlias,
            longUrl: trimmedUrl,
            createdAt: new Date().toISOString(),
            clicks: 0,
            lastAccessedAt: null
          },
          ConditionExpression: 'attribute_not_exists(code)'
        })
      );

      return res.status(201).json({
        code: cleanAlias,
        shortUrl,
        originalLength: trimmedUrl.length,
        shortLength: shortUrl.length,
        charactersSaved: trimmedUrl.length - shortUrl.length
      });
    } catch (err) {
      if (err.name === 'ConditionalCheckFailedException') {
        return res.status(409).json({ error: `The custom alias "${cleanAlias}" is already taken.` });
      }
      console.error('DynamoDB Put Error:', err);
      return res.status(500).json({ error: 'Database error saving short link.' });
    }
  }

  // Random Base62 code generation (6 chars default, bump to 7 after 5 collisions)
  let code = null;
  let codeLength = 6;
  let attempts = 0;

  while (attempts < 10) {
    if (attempts >= 5) {
      codeLength = 7;
    }
    const candidate = generateRandomCode(codeLength);
    const candidateShortUrl = `https://${SHORT_DOMAIN}/${candidate}`;

    // HARD LENGTH RULE
    if (candidateShortUrl.length >= trimmedUrl.length) {
      return res.status(422).json({
        error: 'This URL is already shorter than the generated link',
        originalLength: trimmedUrl.length,
        shortLength: candidateShortUrl.length,
        charactersSaved: trimmedUrl.length - candidateShortUrl.length
      });
    }

    try {
      await docClient.send(
        new PutCommand({
          TableName: TABLE_NAME,
          Item: {
            code: candidate,
            longUrl: trimmedUrl,
            createdAt: new Date().toISOString(),
            clicks: 0,
            lastAccessedAt: null
          },
          ConditionExpression: 'attribute_not_exists(code)'
        })
      );
      code = candidate;
      break;
    } catch (err) {
      if (err.name === 'ConditionalCheckFailedException') {
        attempts++;
        continue;
      }
      console.error('DynamoDB Put Error:', err);
      return res.status(500).json({ error: 'Database error saving short link.' });
    }
  }

  if (!code) {
    return res.status(503).json({ error: 'Could not generate unique short link. Please retry.' });
  }

  const finalShortUrl = `https://${SHORT_DOMAIN}/${code}`;
  return res.status(201).json({
    code,
    shortUrl: finalShortUrl,
    originalLength: trimmedUrl.length,
    shortLength: finalShortUrl.length,
    charactersSaved: trimmedUrl.length - finalShortUrl.length
  });
});

// GET /:code - Redirect with atomic click counter increment
app.get('/:code', async (req, res) => {
  const code = req.params.code;

  if (RESERVED_ALIASES.has(code.toLowerCase())) {
    return res.status(404).send('Not Found');
  }

  try {
    const getResult = await docClient.send(
      new GetCommand({
        TableName: TABLE_NAME,
        Key: { code }
      })
    );

    if (!getResult.Item) {
      res.status(404);
      if (req.accepts('html')) {
        return res.send(`
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>404 - Link Not Found</title>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #0f172a; color: #f8fafc; text-align: center; }
              .box { max-width: 480px; padding: 2.5rem; background: #1e293b; border-radius: 12px; box-shadow: 0 10px 25px rgba(0,0,0,0.4); border: 1px solid #334155; }
              h1 { font-size: 3rem; margin: 0 0 1rem; color: #f43f5e; }
              p { font-size: 1.1rem; line-height: 1.6; color: #94a3b8; margin-bottom: 2rem; }
              a { display: inline-block; padding: 0.75rem 1.5rem; background: #2563eb; color: #fff; text-decoration: none; border-radius: 8px; font-weight: 600; transition: background 0.2s; }
              a:hover { background: #1d4ed8; }
            </style>
          </head>
          <body>
            <div class="box">
              <h1>404</h1>
              <p>The short link <strong>/${encodeURIComponent(code)}</strong> does not exist or has been removed.</p>
              <a href="/">Create a New Short Link</a>
            </div>
          </body>
          </html>
        `);
      }
      return res.json({ error: 'Short link not found' });
    }

    const longUrl = getResult.Item.longUrl;

    // Atomically increment clicks and record lastAccessedAt
    docClient.send(
      new UpdateCommand({
        TableName: TABLE_NAME,
        Key: { code },
        UpdateExpression: 'ADD clicks :one SET lastAccessedAt = :now',
        ExpressionAttributeValues: {
          ':one': 1,
          ':now': new Date().toISOString()
        }
      })
    ).catch(err => console.error('Error updating click analytics:', err));

    return res.redirect(REDIRECT_STATUS, longUrl);
  } catch (error) {
    console.error('Redirect error:', error);
    return res.status(500).send('Internal Server Error');
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`URL Shortener running on port ${PORT}`);
  console.log(`Domain: https://${SHORT_DOMAIN} (redirect status: ${REDIRECT_STATUS})`);
  console.log(`DynamoDB Table: ${TABLE_NAME} (${AWS_REGION})`);
});
