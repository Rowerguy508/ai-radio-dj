import { handleFlags } from '../src/flags-handler.js';

/** Public app flags (#525). Web-signature handler; reads only env. See src/flags-handler.ts. */
export default {
  fetch(request: Request): Response {
    return handleFlags(request, process.env);
  },
};
