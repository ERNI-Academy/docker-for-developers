import { Request, Response } from 'express';
import express from 'express';
import { Pool } from 'pg';
import { createClient } from 'redis';
import path from 'path';
import fs from 'fs/promises';

const app = express();
const port = process.env.PORT || 3000;

// Serve static files (if any)
app.use(express.static('public'));

// PostgreSQL connection
const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

// Redis connection
const redis = createClient({
  url: `redis://${process.env.REDIS_HOST}:${process.env.REDIS_PORT}`
});

redis.connect().catch(console.error);

// Root endpoint - Landing page
app.get('/', async (req: Request, res: Response) => {
  try {
    const templatePath = path.join(__dirname, 'templates', 'index.html');
    const html = await fs.readFile(templatePath, 'utf-8');
    res.send(html);
  } catch (error) {
    console.error('Error reading template:', error);
    res.status(500).send('Internal Server Error');
  }
});

// Health check endpoint
app.get('/health', (req: Request, res: Response) => {
  res.json({ status: 'ok' });
});

// Example endpoint using both Postgres and Redis
app.get('/users', async (req: Request, res: Response) => {
  try {
    // Try to get cached data
    const cached = await redis.get('users');
    if (cached) {
      return res.json(JSON.parse(cached));
    }

    // If not cached, get from database
    const result = await pool.query('SELECT * FROM users');
    const users = result.rows;

    // Cache the results
    await redis.set('users', JSON.stringify(users), {
      EX: 60 // Cache for 60 seconds
    });

    res.json(users);
  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
