"""
MemoryMate MCP Agent Server — Tools for Reminders and Medications

Provides MCP tools for the voice agent:
  - get_current_datetime() - Get current date, time, and day of week
  - set_reminder(title, time) - Set a reminder at specific time
  - get_all_reminders() - Get all active reminders
  - get_latest_reminders(count) - Get latest N reminders
  - add_medication(drug, dose, times, condition) - Add medication to schedule
  - get_all_medications() - Get all medications in schedule
  - get_latest_medication() - Get next upcoming medication

Run as MCP server:
    python3 mcp_agent_server.py dev     (for testing)
    python3 mcp_agent_server.py         (stdio transport for MCP client)
"""

import sys
import os
import logging
from datetime import datetime, timedelta
from typing import List, Dict, Any
from pymongo import MongoClient
from mcp.server.fastmcp import FastMCP
import config

# ============================================================================
# LOGGING
# ============================================================================

logging.basicConfig(
    level=config.LOG_LEVEL,
    format=config.LOG_FORMAT,
    handlers=[
        logging.FileHandler("mcp_agent_server.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("MCP_AgentServer")

# ============================================================================
# MONGODB CONNECTION
# ============================================================================

mongo_client = MongoClient(config.MONGO_URL)
db = mongo_client[config.DB_NAME]

# ============================================================================
# MCP SERVER SETUP
# ============================================================================

mcp = FastMCP("MemoryMateAgent")

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def get_mongodb():
    """Get MongoDB database instance."""
    global db
    try:
        db.client.admin.command('ping')
        return db
    except Exception as e:
        logger.error(f"MongoDB connection error: {e}")
        raise

def parse_time_input(time_str: str) -> str:
    """
    Parse user's time input and return in HH:MM format.
    Handles natural language like "2 pm", "14:00", "in 5 minutes", etc.
    """
    time_str = time_str.lower().strip()
    
    # Handle "in X minutes"
    if "in " in time_str and "minute" in time_str:
        try:
            import re
            match = re.search(r'in (\d+)', time_str)
            if match:
                minutes = int(match.group(1))
                future_time = datetime.now() + timedelta(minutes=minutes)
                return future_time.strftime("%H:%M")
        except:
            pass
    
    # Handle "X am/pm"
    if "am" in time_str or "pm" in time_str:
        try:
            from datetime import datetime as dt
            parsed = dt.strptime(time_str.replace("am", "").replace("pm", "").strip(), "%I")
            if "pm" in time_str and parsed.hour != 12:
                parsed = parsed.replace(hour=parsed.hour + 12)
            elif "am" in time_str and parsed.hour == 12:
                parsed = parsed.replace(hour=0)
            return parsed.strftime("%H:%M")
        except:
            pass
    
    # Already in HH:MM format
    if ":" in time_str:
        return time_str
    
    # Fallback: use as-is
    return time_str

# ============================================================================
# MCP TOOLS
# ============================================================================

@mcp.tool()
async def get_current_datetime() -> Dict[str, Any]:
    """
    Get the current date, time, and day of week.
    
    Use this to understand what time it is now so you can:
    - Compare with medication times to see what should be taken today
    - Determine what the next medication to take is
    - Tell the user what medications they have scheduled for today
    
    Returns:
        Dictionary with current datetime info formatted for easy comparison
    """
    try:
        now = datetime.now()
        day_name = now.strftime("%A")  # e.g., "Monday"
        date_str = now.strftime("%Y-%m-%d")  # e.g., "2026-04-25"
        time_str = now.strftime("%H:%M")  # e.g., "14:30"
        
        logger.info(f"Current datetime: {date_str} {time_str} ({day_name})")
        
        return {
            "status": "success",
            "current_date": date_str,
            "current_time": time_str,
            "day_of_week": day_name,
            "full_datetime": f"{date_str} {time_str} {day_name}",
            "message": f"Current time is {time_str} on {day_name}, {date_str}",
        }
    except Exception as e:
        logger.error(f"Error getting current datetime: {e}")
        return {
            "status": "error",
            "message": f"Failed to get current datetime: {str(e)}",
        }


@mcp.tool()
async def set_reminder(title: str, time_str: str) -> Dict[str, Any]:
    """
    Set a reminder with a title and time.
    
    Args:
        title: What to be reminded about (e.g., "Take medication", "Call doctor")
        time_str: When to be reminded (e.g., "2 pm", "14:00", "in 30 minutes")
    
    Returns:
        Dictionary with reminder_id, title, time, and status
    """
    try:
        # Parse time
        reminder_time = parse_time_input(time_str)
        
        # Create reminder document
        reminder_doc = {
            "title": title,
            "time": reminder_time,
            "created_at": datetime.utcnow(),
            "status": "active",
        }
        
        db = get_mongodb()
        result = db["reminders"].insert_one(reminder_doc)
        
        logger.info(f"Reminder created: {title} at {reminder_time}")
        
        return {
            "status": "success",
            "reminder_id": str(result.inserted_id),
            "title": title,
            "time": reminder_time,
            "message": f"Reminder set: {title} at {reminder_time}",
        }
    except Exception as e:
        logger.error(f"Error setting reminder: {e}")
        return {
            "status": "error",
            "message": f"Failed to set reminder: {str(e)}",
        }


@mcp.tool()
async def get_all_reminders() -> Dict[str, Any]:
    """
    Get all active reminders.
    
    Returns:
        List of all reminders with their details
    """
    try:
        db = get_mongodb()
        reminders = list(db["reminders"].find({"status": "active"}).sort("time", 1))
        
        # Convert ObjectId to string
        for r in reminders:
            r["_id"] = str(r["_id"])
        
        if not reminders:
            return {
                "status": "success",
                "count": 0,
                "reminders": [],
                "message": "No reminders set",
            }
        
        logger.info(f"Retrieved {len(reminders)} reminders")
        
        return {
            "status": "success",
            "count": len(reminders),
            "reminders": reminders,
            "message": f"You have {len(reminders)} active reminder(s)",
        }
    except Exception as e:
        logger.error(f"Error getting reminders: {e}")
        return {
            "status": "error",
            "message": f"Failed to retrieve reminders: {str(e)}",
        }


@mcp.tool()
async def get_latest_reminders(count: int = 3) -> Dict[str, Any]:
    """
    Get the latest N reminders.
    
    Args:
        count: Number of latest reminders to retrieve (default: 3)
    
    Returns:
        List of latest reminders
    """
    try:
        db = get_mongodb()
        count = min(max(1, count), 10)  # Clamp between 1-10
        
        reminders = list(
            db["reminders"]
            .find({"status": "active"})
            .sort("created_at", -1)
            .limit(count)
        )
        
        # Convert ObjectId to string
        for r in reminders:
            r["_id"] = str(r["_id"])
        
        if not reminders:
            return {
                "status": "success",
                "count": 0,
                "reminders": [],
                "message": "No reminders found",
            }
        
        logger.info(f"Retrieved {len(reminders)} latest reminders")
        
        return {
            "status": "success",
            "count": len(reminders),
            "reminders": reminders,
            "message": f"Here are your {len(reminders)} latest reminder(s)",
        }
    except Exception as e:
        logger.error(f"Error getting latest reminders: {e}")
        return {
            "status": "error",
            "message": f"Failed to retrieve reminders: {str(e)}",
        }


@mcp.tool()
async def add_medication(drug: str, dose: str, times: str, condition: str = "") -> Dict[str, Any]:
    """
    Add a medication to the schedule.
    
    Args:
        drug: Medication name (e.g., "Aspirin", "Lisinopril")
        dose: Dosage amount (e.g., "500mg", "10mg twice daily")
        times: Medication times as comma-separated list (e.g., "09:00,14:00,21:00" or "9 am, 2 pm")
        condition: Medical condition it's for (e.g., "hypertension", "diabetes")
    
    Returns:
        Dictionary with medication_id and status
    """
    try:
        # Parse times - handle both "HH:MM" format and natural language
        time_list = []
        for time_item in times.split(","):
            time_item = time_item.strip()
            parsed_time = parse_time_input(time_item)
            time_list.append(parsed_time)
        
        # Create medication document
        med_doc = {
            "drug": drug,
            "dose": dose,
            "times": time_list,
            "condition": condition,
            "created_at": datetime.utcnow(),
        }
        
        db = get_mongodb()
        result = db["medications"].insert_one(med_doc)
        
        logger.info(f"Medication added: {drug}, {dose} at {', '.join(time_list)}")
        
        return {
            "status": "success",
            "medication_id": str(result.inserted_id),
            "drug": drug,
            "dose": dose,
            "times": time_list,
            "condition": condition,
            "message": f"Medication saved: {drug}, {dose} at {', '.join(time_list)}",
        }
    except Exception as e:
        logger.error(f"Error adding medication: {e}")
        return {
            "status": "error",
            "message": f"Failed to add medication: {str(e)}",
        }


@mcp.tool()
async def get_latest_medication() -> Dict[str, Any]:
    """
    Get the next medication to take (earliest upcoming medication by time).
    
    Returns:
        Dictionary with medication details or message if none found
    """
    try:
        db = get_mongodb()
        
        # Find all medications
        medications = list(db["medications"].find())
        
        if not medications:
            return {
                "status": "success",
                "medication": None,
                "message": "No medications scheduled",
            }
        
        # Get current time
        current_hour = datetime.now().hour
        current_minute = datetime.now().minute
        current_time_str = f"{current_hour:02d}:{current_minute:02d}"
        
        # Find next medication
        next_med = None
        min_diff = float('inf')
        
        for med in medications:
            times = med.get("times", [])
            for med_time in times:
                try:
                    # Calculate time difference
                    med_hour, med_minute = map(int, med_time.split(":"))
                    med_total_minutes = med_hour * 60 + med_minute
                    current_total_minutes = current_hour * 60 + current_minute
                    
                    diff = med_total_minutes - current_total_minutes
                    if diff < 0:
                        diff += 24 * 60  # Next day
                    
                    if diff < min_diff:
                        min_diff = diff
                        next_med = {
                            "_id": str(med["_id"]),
                            "drug": med["drug"],
                            "dose": med["dose"],
                            "time": med_time,
                            "condition": med.get("condition", ""),
                        }
                except:
                    continue
        
        if next_med is None:
            return {
                "status": "success",
                "medication": None,
                "message": "No upcoming medications",
            }
        
        hours_until = min_diff // 60
        minutes_until = min_diff % 60
        
        logger.info(f"Next medication: {next_med['drug']} at {next_med['time']}")
        
        return {
            "status": "success",
            "medication": next_med,
            "time_until": f"{hours_until}h {minutes_until}m",
            "message": f"Next medication: {next_med['drug']}, {next_med['dose']} in {hours_until}h {minutes_until}m",
        }
    except Exception as e:
        logger.error(f"Error getting latest medication: {e}")
        return {
            "status": "error",
            "message": f"Failed to retrieve medication: {str(e)}",
        }


@mcp.tool()
async def get_all_medications() -> Dict[str, Any]:
    """
    Get all medications in the schedule.
    
    Returns:
        List of all medications with their details (drug name, dose, times, condition)
    """
    try:
        db = get_mongodb()
        medications = list(db["medications"].find())
        
        # Convert ObjectId to string
        for med in medications:
            med["_id"] = str(med["_id"])
        
        if not medications:
            return {
                "status": "success",
                "count": 0,
                "medications": [],
                "message": "No medications scheduled",
            }
        
        logger.info(f"Retrieved {len(medications)} medications")
        
        return {
            "status": "success",
            "count": len(medications),
            "medications": medications,
            "message": f"You have {len(medications)} medication(s) scheduled",
        }
    except Exception as e:
        logger.error(f"Error getting all medications: {e}")
        return {
            "status": "error",
            "message": f"Failed to retrieve medications: {str(e)}",
        }


# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    logger.info("Starting MemoryMate MCP Agent Server...")
    
    if len(sys.argv) > 1 and sys.argv[1] == "dev":
        logger.info("Running in dev mode (no transport)")
        mcp.run()  # Dev server
    else:
        logger.info("Running with stdio transport")
        mcp.run(transport="stdio")  # Stdio transport for MCP client
