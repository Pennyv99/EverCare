"""
Face Embedding & Recognition Helpers
Shared module for embedding generation and face matching logic.
Used by both face_service.py (background model manager) and main.py (FastAPI).
"""

import numpy as np
from scipy.spatial.distance import cosine
from typing import List, Optional


def compute_embedding_similarity(embedding1: List[float], embedding2: List[float]) -> float:
    """
    Compute cosine similarity between two embeddings.
    Returns value between 0 and 1 (1 = identical, 0 = completely different).
    """
    e1 = np.array(embedding1)
    e2 = np.array(embedding2)
    # Cosine distance ranges 0-2, convert to similarity 0-1
    distance = cosine(e1, e2)
    similarity = 1 - (distance / 2)  # Normalize to 0-1 range
    return float(similarity)


async def match_face_embedding(
    query_embedding: List[float],
    db,
    threshold: float = 0.6,
) -> Optional[dict]:
    """
    Match a query embedding against all enrolled faces in database.
    Returns matched face document or None if no match found.
    Threshold: 0.6 is good for secure matching, 0.5 for lenient.
    """
    if db is None:
        raise RuntimeError("Database not initialized")

    try:
        enrolled_faces = await db["faces"].find({}).to_list(None)

        best_match = None
        best_similarity = threshold

        for face_doc in enrolled_faces:
            if "embeddings" not in face_doc or not face_doc["embeddings"]:
                continue

            # Compare against all embeddings for this person
            for stored_embedding in face_doc["embeddings"]:
                similarity = compute_embedding_similarity(query_embedding, stored_embedding)

                if similarity > best_similarity:
                    best_similarity = similarity
                    best_match = {
                        "document": face_doc,
                        "confidence": best_similarity,
                    }

        if best_match:
            return best_match

        return None

    except Exception as e:
        print(f"Error matching face embedding: {e}")
        raise
