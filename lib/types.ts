export type GameState = "lobby" | "guessing" | "revealed" | "finished";

export const TOTAL_ROUNDS = 10;
export const ROUND_SECONDS = 60;

export interface Character {
  key: string;
  name: string;
  imageUrl: string;
  imageCredit: string;
  emoji: string;
}

export interface Assignment {
  seat: number;
  revealed: boolean;
  character: Character;
}

export interface PlayerRow {
  id: string;
  seat: number;
  name: string;
  ready: boolean;
  revealReady: boolean;
  isMe: boolean;
  lastSeen: number;
}

export interface RoundInfo {
  index: number;
  clue: string;
  category: string;
  total: number;
}

export interface GameRow {
  id: string;
  code: string;
  state: GameState;
  round_index: number;
  use_timer: boolean;
  round_started_at: string | null;
  updated_at: string;
}

export interface Snapshot {
  serverNow: number;
  game: GameRow;
  players: PlayerRow[];
  round: RoundInfo | null;
  assignments: Assignment[];
}

export interface RoomRef {
  game_id: string;
  code: string;
  seat: number;
}
