import { Hono } from "hono";

export const createHealthController = () => {
  const app = new Hono();

  app.get("/", async (c) => {
    return c.json({
      status: "healthy",
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      memory: process.memoryUsage(),
      version: "4.3.2"
    });
  });

  return app;
};